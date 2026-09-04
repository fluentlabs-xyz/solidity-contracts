//! Spec test for design.md:267 — where the loop's one piece of state goes next
//! (per R1: consecutive rounds; per R4: an interruption resumes from the chain's current
//! round with no back-fill; per R5: a round another party published is skipped).

use drand_publisher::{next_after, Disposition};

#[test]
fn the_counter_steps_by_one_holds_or_resumes_from_the_chain() {
    // A round that landed — or that someone else published — moves the counter on by one.
    assert_eq!(next_after(1_000, Disposition::Advance, 5_000), 1_001);

    // A round the chain clock has not reached yet is retried, not skipped.
    assert_eq!(next_after(1_000, Disposition::Retry, 5_000), 1_000);

    // A counter left behind by an interruption resumes at the chain's current round,
    // and the rounds in between are not back-filled.
    assert_eq!(next_after(1_000, Disposition::Resync, 5_000), 5_000);
}
