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
 * panic). The first time one lands on a CPU that is idle, it prints that
 * CPU's local APIC state: IRR and ISR (pending and in-service vectors,
 * e.g. a reschedule IPI that was delivered but did not wake the CPU), TPR
 * and PPR, and the idle task's need_resched and polling flags. That tells
 * a wakeup lost before the APIC from one the APIC holds while the CPU
 * stays in its C-state.
 */
#include <asm/apic.h>
#include <asm/irq_vectors.h>
#include <asm/nmi.h>
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

static DEFINE_PER_CPU(bool, deadman_idle_dumped);

/* apic_read() goes through a static call that is not exported to modules. */
static u32 deadman_apic_read(u32 reg)
{
	return apic->read(reg);
}

static int deadman_idle_nmi(unsigned int type, struct pt_regs *regs)
{
	u32 irr[8], isr[8];
	int i;

	if (!(atomic_read(&deadman_watching) || idle_nmi_always) || !is_idle_task(current) ||
	    this_cpu_read(deadman_idle_dumped))
		return NMI_DONE;
	this_cpu_write(deadman_idle_dumped, true);

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

static void deadman_watch(bool on)
{
	int cpu;

	if (on)
		for_each_possible_cpu(cpu)
			per_cpu(deadman_idle_dumped, cpu) = false;
	atomic_set(&deadman_watching, on);
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
		deadman_watch(false);
		if (cancel_delayed_work(&deadman_work))
			pr_info("sleep_deadman: disarmed\n");
		break;
	case PM_SUSPEND_PREPARE:
		deadman_watch(true);
		break;
	case PM_POST_SUSPEND:
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
	int r;

	r = register_nmi_handler(NMI_LOCAL, deadman_idle_nmi, 0, "sleep_deadman");
	if (r)
		return r;
	r = register_pm_notifier(&deadman_nb);
	if (r)
		unregister_nmi_handler(NMI_LOCAL, "sleep_deadman");
	return r;
}

static void __exit deadman_exit(void)
{
	unregister_pm_notifier(&deadman_nb);
	unregister_nmi_handler(NMI_LOCAL, "sleep_deadman");
	cancel_delayed_work_sync(&deadman_work);
}

module_init(deadman_init);
module_exit(deadman_exit);

MODULE_DESCRIPTION("Panic and reboot when a hibernation hangs");
MODULE_LICENSE("GPL");
