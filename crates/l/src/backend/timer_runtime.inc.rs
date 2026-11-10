// Reference clock and ordered timer queue. All access occurs in a scheduler turn.
thread_local! {
    static L_TIMERS: std::cell::RefCell<std::collections::BTreeSet<(std::time::Instant, usize)>> =
        const { std::cell::RefCell::new(std::collections::BTreeSet::new()) };
}

fn l_check_sleep(ms: i64, line: usize, col: usize) -> i64 {
    if !(0..=L_MAX_SLEEP_MS).contains(&ms) {
        l_panic(line, col, "duración de sleepMs fuera de rango");
    }
    ms
}

async fn l_sleep(ms: i64) {
    if ms == 0 {
        return;
    }
    let task = l_current();
    let deadline = std::time::Instant::now()
        .checked_add(std::time::Duration::from_millis(ms as u64))
        .unwrap_or_else(|| l_panic(1, 1, "deadline de sleepMs fuera de rango"));
    l_with(task, |r| r.timer = Some(deadline));
    L_TIMERS.with(|timers| timers.borrow_mut().insert((deadline, task)));
    std::future::poll_fn(|_| {
        if l_with(task, |r| r.timer.is_none()) == Some(true) {
            std::task::Poll::Ready(())
        } else {
            std::task::Poll::Pending
        }
    }).await
}

fn l_cancel_timer(task: usize) {
    if let Some(Some(deadline)) = l_with(task, |r| r.timer.take()) {
        L_TIMERS.with(|timers| timers.borrow_mut().remove(&(deadline, task)));
    }
}

fn l_pump_timers() -> Option<std::time::Duration> {
    L_TIMERS.with(|timers| {
        let mut queue = timers.borrow_mut();
        if queue.is_empty() {
            return None;
        }
        let now = std::time::Instant::now();
        while let Some(&(deadline, task)) = queue.first() {
            if let Some(delay) = deadline.checked_duration_since(now)
                && !delay.is_zero()
            {
                return Some(delay);
            }
            queue.pop_first();
            if l_with(task, |r| r.timer.take()) == Some(Some(deadline)) {
                l_wake(task);
            }
        }
        None
    })
}
