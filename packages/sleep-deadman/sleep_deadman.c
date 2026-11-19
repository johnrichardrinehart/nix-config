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
 */
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
		if (!timeout_secs)
			break;
		/* system_dfl_wq is not freezable: it runs while tasks are frozen. */
		mod_delayed_work(system_dfl_wq, &deadman_work,
				 msecs_to_jiffies((unsigned long)timeout_secs * MSEC_PER_SEC));
		pr_info("sleep_deadman: armed for %u s\n", timeout_secs);
		break;
	case PM_POST_HIBERNATION:
		if (cancel_delayed_work(&deadman_work))
			pr_info("sleep_deadman: disarmed\n");
		break;
	}
	return NOTIFY_DONE;
}

static struct notifier_block deadman_nb = {
	.notifier_call = deadman_pm_notify,
};

static int __init deadman_init(void)
{
	return register_pm_notifier(&deadman_nb);
}

static void __exit deadman_exit(void)
{
	unregister_pm_notifier(&deadman_nb);
	cancel_delayed_work_sync(&deadman_work);
}

module_init(deadman_init);
module_exit(deadman_exit);

MODULE_DESCRIPTION("Panic and reboot when a hibernation hangs");
MODULE_LICENSE("GPL");
