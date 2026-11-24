// SPDX-License-Identifier: GPL-2.0
/*
 * sleep_deadman: panic when a hibernation does not finish in time.
 *
 * A hibernation that blocks once user space is frozen leaves the machine
 * wedged without a trace: journald is frozen, the hung task detector stands
 * down from PM_HIBERNATION_PREPARE to PM_POST_HIBERNATION
 * (kernel/hung_task.c), and before 7.4 the DPM watchdog covers only the
 * device suspend and resume callbacks. No image header gets written either,
 * so the next boot cannot resume and the session is lost.
 *
 * This module arms a timer at PM_HIBERNATION_PREPARE and disarms it at
 * PM_POST_HIBERNATION. If the timer fires first, it prints the stack of
 * every task blocked in uninterruptible sleep, then panics: pstore keeps
 * the end of the kernel log for the next boot, and the machine reboots
 * reboot_secs later instead of staying wedged until its battery is empty.
 *
 * A good hibernation powers off long before the deadline. The restored
 * kernel inherits the pending timer and disarms it at PM_POST_HIBERNATION,
 * once its devices are back, so the deadline covers resume as well. The
 * timer runs on jiffies, which stand still while the machine is off.
 *
 * While a suspend or hibernation is in progress, the module also watches
 * NMIs (backtrace requests from RCU stall reports, lockup detectors and
 * panic). When one lands on a CPU that is idle, it prints that
 * CPU's local APIC state: IRR and ISR (pending and in-service vectors,
 * e.g. a reschedule IPI that was delivered but did not wake the CPU), TPR
 * and PPR, and the idle task's need_resched and polling flags. That tells
 * a wakeup lost before the APIC from one the APIC holds while the CPU
 * stays in its C-state. Each CPU prints at most once every 5 s, so a
 * stray NMI early on does not use up the dump for a later stall.
 */
#include <asm/apic.h>
#include <asm/irq_vectors.h>
#include <asm/nmi.h>
#include <linux/cpuhotplug.h>
#include <linux/hrtimer.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/panic.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/sched/debug.h>
#include <linux/sched/signal.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

static atomic_t deadman_watching;

/* 1: dump idle CPUs on every NMI, also outside sleep (test with sysrq-l). */
static bool idle_nmi_always;
module_param(idle_nmi_always, bool, 0644);
MODULE_PARM_DESC(idle_nmi_always,
		 "Print the APIC state of idle CPUs on NMIs outside suspend/hibernation too (default: false)");

/* jiffies of each CPU's last dump; 0 = none yet */
static DEFINE_PER_CPU(unsigned long, deadman_idle_dumped);

/* apic_read() goes through a static call that is not exported to modules. */
static u32 deadman_apic_read(u32 reg)
{
	return apic->read(reg);
}

/*
 * The local APIC as this CPU sees it: the APIC_BASE MSR, and the ID and ICR
 * read straight through the xAPIC MMIO page. After a hibernation restore one
 * CPU was seen spinning in an IPI send on an ICR that read 0xffffffff, i.e.
 * its MMIO page did not decode.
 */
struct deadman_apic_state {
	u64 base, pat, deftype, syscfg, cr0;
	u32 id, icr, mtrr_sum;
};

/*
 * The MSRs that decide how a physical address is cached: if a CPU's
 * MTRRs or PAT differ from the boot CPU's after resume, a read of the
 * APIC page may be served from somewhere other than the local APIC.
 */
static const u32 deadman_mtrr_msrs[] = {
	0x200, 0x201, 0x202, 0x203, 0x204, 0x205, 0x206, 0x207,
	0x208, 0x209, 0x20a, 0x20b, 0x20c, 0x20d, 0x20e, 0x20f,
	0x250, 0x258, 0x259, 0x268, 0x269, 0x26a, 0x26b, 0x26c,
	0x26d, 0x26e, 0x26f, 0x2ff, 0xc0010010,
};

static u64 deadman_rdmsr(u32 msr)
{
	u64 v;

	return rdmsrq_safe(msr, &v) ? ~0ULL : v;
}

static void deadman_apic_state(struct deadman_apic_state *s)
{
	void __iomem *mmio = (void __iomem *)APIC_BASE;
	u32 sum = 0;
	int i;

	s->base = deadman_rdmsr(MSR_IA32_APICBASE);
	s->pat = deadman_rdmsr(MSR_IA32_CR_PAT);
	s->deftype = deadman_rdmsr(MSR_MTRRdefType);
	s->syscfg = deadman_rdmsr(MSR_AMD64_SYSCFG);
	s->cr0 = read_cr0();
	for (i = 0; i < ARRAY_SIZE(deadman_mtrr_msrs); i++) {
		u64 v = deadman_rdmsr(deadman_mtrr_msrs[i]);

		sum = (sum * 31) ^ lower_32_bits(v) ^ upper_32_bits(v) * 7;
	}
	s->mtrr_sum = sum;
	s->id = readl(mmio + APIC_ID);
	s->icr = readl(mmio + APIC_ICR);
}

/* The boot CPU's view at load, which every CPU should match. */
static struct deadman_apic_state deadman_ref;

static bool deadman_apic_bad(const struct deadman_apic_state *s)
{
	return (s->base & (MSR_IA32_APICBASE_ENABLE | X2APIC_ENABLE |
			   MSR_IA32_APICBASE_BASE)) !=
		       (MSR_IA32_APICBASE_ENABLE | APIC_DEFAULT_PHYS_BASE) ||
	       s->id == ~0U || (s->icr & APIC_ICR_BUSY) ||
	       s->pat != deadman_ref.pat || s->deftype != deadman_ref.deftype ||
	       s->syscfg != deadman_ref.syscfg ||
	       s->mtrr_sum != deadman_ref.mtrr_sum ||
	       (s->cr0 & (X86_CR0_CD | X86_CR0_NW));
}

static void deadman_print_apic(const char *why, int cpu,
			       const struct deadman_apic_state *s)
{
	pr_emerg("sleep_deadman: %s CPU %d APIC_BASE=%llx MMIO ID=%08x ICR=%08x PAT=%llx MTRRdef=%llx SYSCFG=%llx MTRRsum=%08x CR0=%llx\n",
		 why, cpu, s->base, s->id, s->icr, s->pat, s->deftype,
		 s->syscfg, s->mtrr_sum, s->cr0);
}

static void deadman_read_ref(void *unused)
{
	deadman_apic_state(&deadman_ref);
}

static atomic_t deadman_apic_bad_cpus;

static void deadman_check_apic_cpu(void *unused)
{
	struct deadman_apic_state s;

	deadman_apic_state(&s);
	if (deadman_apic_bad(&s)) {
		atomic_inc(&deadman_apic_bad_cpus);
		deadman_print_apic("bad APIC on", smp_processor_id(), &s);
	}
}

/* After a resume: does every CPU's local APIC still decode in xAPIC mode? */
static void deadman_check_apics(const char *when)
{
	atomic_set(&deadman_apic_bad_cpus, 0);
	on_each_cpu(deadman_check_apic_cpu, NULL, 1);
	pr_info("sleep_deadman: APIC check %s: %d of %u CPUs bad\n", when,
		atomic_read(&deadman_apic_bad_cpus), num_online_cpus());
}

static int deadman_idle_nmi(unsigned int type, struct pt_regs *regs)
{
	struct deadman_apic_state s;
	u32 irr[8], isr[8];
	int i;

	if (!(atomic_read(&deadman_watching) || idle_nmi_always))
		return NMI_DONE;
	if (this_cpu_read(deadman_idle_dumped) &&
	    time_before(jiffies, this_cpu_read(deadman_idle_dumped) + 5 * HZ))
		return NMI_DONE;
	this_cpu_write(deadman_idle_dumped, jiffies ?: 1);

	deadman_apic_state(&s);
	deadman_print_apic(is_idle_task(current) ? "idle" : "busy",
			   smp_processor_id(), &s);
	if (!is_idle_task(current))
		return NMI_DONE;

	for (i = 0; i < 8; i++) {
		irr[i] = deadman_apic_read(APIC_IRR + i * 0x10);
		isr[i] = deadman_apic_read(APIC_ISR + i * 0x10);
	}
	pr_emerg("sleep_deadman: idle CPU %d at %pS need_resched=%d polling=%d TPR=%02x PPR=%02x\n",
		 smp_processor_id(), (void *)instruction_pointer(regs),
		 test_tsk_need_resched(current),
		 test_thread_flag(TIF_POLLING_NRFLAG),
		 deadman_apic_read(APIC_TASKPRI) & 0xff, deadman_apic_read(APIC_PROCPRI) & 0xff);
	pr_emerg("sleep_deadman: CPU %d IRR[255..0] %08x %08x %08x %08x %08x %08x %08x %08x\n",
		 smp_processor_id(), irr[7], irr[6], irr[5], irr[4], irr[3], irr[2], irr[1], irr[0]);
	pr_emerg("sleep_deadman: CPU %d ISR[255..0] %08x %08x %08x %08x %08x %08x %08x %08x\n",
		 smp_processor_id(), isr[7], isr[6], isr[5], isr[4], isr[3], isr[2], isr[1], isr[0]);
	pr_emerg("sleep_deadman: CPU %d pending: resched=%d call_func=%d call_func_single=%d timer=%d\n",
		 smp_processor_id(),
		 !!(irr[RESCHEDULE_VECTOR / 32] & BIT(RESCHEDULE_VECTOR % 32)),
		 !!(irr[CALL_FUNCTION_VECTOR / 32] & BIT(CALL_FUNCTION_VECTOR % 32)),
		 !!(irr[CALL_FUNCTION_SINGLE_VECTOR / 32] & BIT(CALL_FUNCTION_SINGLE_VECTOR % 32)),
		 !!(irr[LOCAL_TIMER_VECTOR / 32] & BIT(LOCAL_TIMER_VECTOR % 32)));
	return NMI_DONE;
}

/*
 * While a sleep transition is under way, every online CPU checks every
 * 20 ms that its APIC MMIO page still decodes. A CPU whose page reads
 * 0xffffffff gets its APIC_BASE MSR written back with the same value, to
 * see whether that brings the MMIO decode back.
 */
static bool apic_repair = true;
module_param(apic_repair, bool, 0644);
MODULE_PARM_DESC(apic_repair,
		 "Rewrite APIC_BASE when a CPU's APIC MMIO page stops decoding during sleep (default: true)");

#define DEADMAN_POLL_NS (20 * NSEC_PER_MSEC)
static DEFINE_PER_CPU(struct hrtimer, deadman_poll);
static DEFINE_PER_CPU(bool, deadman_poll_bad);

static enum hrtimer_restart deadman_poll_fn(struct hrtimer *t)
{
	void __iomem *mmio = (void __iomem *)APIC_BASE;
	u32 id = readl(mmio + APIC_ID);
	int cpu = smp_processor_id();

	if (id == ~0U && !this_cpu_read(deadman_poll_bad)) {
		u64 base = deadman_rdmsr(MSR_IA32_APICBASE);

		this_cpu_write(deadman_poll_bad, true);
		pr_emerg("sleep_deadman: CPU %d APIC MMIO stopped decoding (APIC_BASE=%llx)\n",
			 cpu, base);
		if (apic_repair && base != ~0ULL) {
			wrmsrq(MSR_IA32_APICBASE, base);
			id = readl(mmio + APIC_ID);
			pr_emerg("sleep_deadman: CPU %d APIC_BASE rewritten: MMIO ID now %08x\n",
				 cpu, id);
		}
	} else if (id != ~0U && this_cpu_read(deadman_poll_bad)) {
		this_cpu_write(deadman_poll_bad, false);
		pr_emerg("sleep_deadman: CPU %d APIC MMIO decodes again (ID=%08x)\n",
			 cpu, id);
	}
	if (!atomic_read(&deadman_watching))
		return HRTIMER_NORESTART;
	hrtimer_forward_now(t, ns_to_ktime(DEADMAN_POLL_NS));
	return HRTIMER_RESTART;
}

static void deadman_poll_start(void *unused)
{
	hrtimer_start(this_cpu_ptr(&deadman_poll), ns_to_ktime(DEADMAN_POLL_NS),
		      HRTIMER_MODE_REL_PINNED_HARD);
}

static int deadman_cpu_online(unsigned int cpu)
{
	if (atomic_read(&deadman_watching))
		deadman_poll_start(NULL);
	return 0;
}

static int deadman_cpu_offline(unsigned int cpu)
{
	hrtimer_cancel(this_cpu_ptr(&deadman_poll));
	return 0;
}

static enum cpuhp_state deadman_cpuhp;

static void deadman_watch(bool on)
{
	int cpu;

	if (on)
		for_each_possible_cpu(cpu) {
			per_cpu(deadman_idle_dumped, cpu) = 0;
			per_cpu(deadman_poll_bad, cpu) = false;
		}
	atomic_set(&deadman_watching, on);
	if (on) {
		on_each_cpu(deadman_poll_start, NULL, 1);
	} else {
		for_each_possible_cpu(cpu)
			hrtimer_cancel(per_cpu_ptr(&deadman_poll, cpu));
	}
}

static unsigned int timeout_secs = 300;
module_param(timeout_secs, uint, 0644);
MODULE_PARM_DESC(timeout_secs,
		 "Seconds a hibernation may take, from prepare to power-off or to restored devices (0: never panic)");

static int reboot_secs = 10;
module_param(reboot_secs, int, 0644);
MODULE_PARM_DESC(reboot_secs, "Seconds from the panic to the reboot");

static void show_blocked_tasks(void)
{
	struct task_struct *g, *t;

	rcu_read_lock();
	for_each_process_thread(g, t) {
		unsigned int state = READ_ONCE(t->__state);

		/*
		 * Frozen tasks are in TASK_FROZEN, idle kernel threads in
		 * TASK_IDLE (with TASK_NOLOAD): neither is what hangs.
		 */
		if ((state & TASK_UNINTERRUPTIBLE) && !(state & TASK_NOLOAD))
			sched_show_task(t);
	}
	rcu_read_unlock();
}

static void deadman_fire(struct work_struct *work)
{
	pr_emerg("sleep_deadman: hibernation did not finish within %u s; blocked tasks follow\n",
		 timeout_secs);
	show_blocked_tasks();
	panic_timeout = reboot_secs;
	panic("sleep_deadman: hibernation hung");
}

static DECLARE_DELAYED_WORK(deadman_work, deadman_fire);

static int deadman_pm_notify(struct notifier_block *nb, unsigned long action,
			     void *data)
{
	switch (action) {
	case PM_HIBERNATION_PREPARE:
		deadman_watch(true);
		if (!timeout_secs)
			break;
		/* system_dfl_wq is not freezable: it runs while tasks are frozen. */
		mod_delayed_work(system_dfl_wq, &deadman_work,
				 msecs_to_jiffies((unsigned long)timeout_secs * MSEC_PER_SEC));
		pr_info("sleep_deadman: armed for %u s\n", timeout_secs);
		break;
	case PM_POST_HIBERNATION:
		deadman_check_apics("after hibernation");
		deadman_watch(false);
		if (cancel_delayed_work(&deadman_work))
			pr_info("sleep_deadman: disarmed\n");
		break;
	case PM_SUSPEND_PREPARE:
		deadman_watch(true);
		break;
	case PM_POST_SUSPEND:
		deadman_check_apics("after suspend");
		deadman_watch(false);
		break;
	}
	return NOTIFY_DONE;
}

static struct notifier_block deadman_nb = {
	.notifier_call = deadman_pm_notify,
};

static int __init deadman_init(void)
{
	int cpu, r;

	for_each_possible_cpu(cpu)
		hrtimer_setup(per_cpu_ptr(&deadman_poll, cpu), deadman_poll_fn,
			      CLOCK_MONOTONIC, HRTIMER_MODE_REL_PINNED_HARD);
	r = cpuhp_setup_state_nocalls(CPUHP_AP_ONLINE_DYN, "sleep_deadman:online",
				      deadman_cpu_online, deadman_cpu_offline);
	if (r < 0)
		return r;
	deadman_cpuhp = r;
	r = register_nmi_handler(NMI_LOCAL, deadman_idle_nmi, 0, "sleep_deadman");
	if (r) {
		cpuhp_remove_state_nocalls(deadman_cpuhp);
		return r;
	}
	r = register_pm_notifier(&deadman_nb);
	if (r) {
		unregister_nmi_handler(NMI_LOCAL, "sleep_deadman");
		cpuhp_remove_state_nocalls(deadman_cpuhp);
		return r;
	}
	smp_call_function_single(0, deadman_read_ref, NULL, 1);
	deadman_print_apic("reference", 0, &deadman_ref);
	deadman_check_apics("at load");
	return 0;
}

static void __exit deadman_exit(void)
{
	unregister_pm_notifier(&deadman_nb);
	deadman_watch(false);
	cpuhp_remove_state_nocalls(deadman_cpuhp);
	unregister_nmi_handler(NMI_LOCAL, "sleep_deadman");
	cancel_delayed_work_sync(&deadman_work);
}

module_init(deadman_init);
module_exit(deadman_exit);

MODULE_DESCRIPTION("Panic and reboot when a hibernation hangs");
MODULE_LICENSE("GPL");
