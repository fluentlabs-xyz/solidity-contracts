//! How long the loop holds a round that came back not ready: until the beacon is due,
//! then a bounded retry. Both halves matter — the first is the publishing cadence, the
//! second is the load a stalled beacon puts on a relay that asks not to be re-asked
//! inside its three-second `max-age`.

use std::time::Duration;

use drand_publisher::wait_before_retry;

const PERIOD: Duration = Duration::from_secs(3);
const MARGIN: Duration = Duration::from_millis(250);

#[test]
fn a_round_that_is_not_due_is_waited_out_rather_than_polled_for() {
    // Two seconds early: hold those two seconds, plus the margin a relay needs to have
    // the beacon in hand. One request, sent once the round exists.
    assert_eq!(
        wait_before_retry(1_000, 1_002, 0, PERIOD),
        Duration::from_secs(2) + MARGIN
    );

    // The attempt count does not shorten a wait for a round that cannot exist yet: the
    // schedule, not the number of tries, is what says when to ask.
    assert_eq!(
        wait_before_retry(1_000, 1_002, 7, PERIOD),
        Duration::from_secs(2) + MARGIN
    );

    // One second before, the whole wait is inside a single period — the case that used
    // to cost a full interval and put a sawtooth into the cadence.
    assert!(wait_before_retry(1_000, 1_001, 0, PERIOD) < PERIOD);
}

#[test]
fn a_round_that_is_due_is_retried_from_short_up_to_the_period() {
    // Due this second, and late rather than absent: ask again shortly.
    assert_eq!(wait_before_retry(1_002, 1_002, 0, PERIOD), Duration::from_millis(250));
    assert_eq!(wait_before_retry(1_002, 1_002, 1, PERIOD), Duration::from_millis(500));
    assert_eq!(wait_before_retry(1_002, 1_002, 2, PERIOD), Duration::from_secs(1));
    assert_eq!(wait_before_retry(1_002, 1_002, 3, PERIOD), Duration::from_secs(2));

    // From here the ceiling holds: a beacon that never arrives is asked for once per
    // period, which is the cadence the relay's own cache directive names.
    assert_eq!(wait_before_retry(1_002, 1_002, 4, PERIOD), PERIOD);
    assert_eq!(wait_before_retry(1_002, 1_002, 40, PERIOD), PERIOD);

    // Long past due — a counter behind the beacon, catching up — is the same ceiling and
    // never a longer wait than the period.
    assert_eq!(wait_before_retry(9_000, 1_002, 40, PERIOD), PERIOD);
}
