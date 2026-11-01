# HassControl simulator run

| scenario | device | feature | checks | result |
|---|---|---|---:|---|
| [f7_loopback_http](f7_loopback_http/REPORT.md) | fenix7x | loopback http | 4 | pass |
| [f7_http_uppercase](f7_http_uppercase/REPORT.md) | fenix7x | loopback http | 2 | pass |
| [f7_http_localhost](f7_http_localhost/REPORT.md) | fenix7x | loopback http | 2 | pass |
| [f7_http_bad_host](f7_http_bad_host/REPORT.md) | fenix7x | loopback http | 4 | pass |
| [f7_http_userinfo](f7_http_userinfo/REPORT.md) | fenix7x | loopback http | 4 | pass |
| [f7_lock_no_confirmation](f7_lock_no_confirmation/REPORT.md) | fenix7x | lock confirmation | 1 | pass |
| [f7_lock_yesno](f7_lock_yesno/REPORT.md) | fenix7x | lock confirmation | 7 | pass |
| [f7_lock_pin_ok](f7_lock_pin_ok/REPORT.md) | fenix7x | lock confirmation | 7 | pass |
| [f7_lock_pin_wrong_and_lockout](f7_lock_pin_wrong_and_lockout/REPORT.md) | fenix7x | lock confirmation | 10 | pass |
| [f7_lock_pin_delete_and_leave](f7_lock_pin_delete_and_leave/REPORT.md) | fenix7x | lock confirmation | 5 | pass |
| [f7_lock_pin_not_set](f7_lock_pin_not_set/REPORT.md) | fenix7x | lock confirmation | 2 | pass |
| [f7_connection_wait](f7_connection_wait/REPORT.md) | fenix7x | waiting for the phone | 5 | 2 of 5 failed |
| [f7_wifi_offer_and_cancel](f7_wifi_offer_and_cancel/REPORT.md) | fenix7x | Wi-Fi/LTE | 5 | 2 of 5 failed |
| [f7_wifi_confirm_starts_sync](f7_wifi_confirm_starts_sync/REPORT.md) | fenix7x | Wi-Fi/LTE | 6 | 3 of 6 failed |
| [f7_timers_rapid_actions](f7_timers_rapid_actions/REPORT.md) | fenix7x | timers (#101) | 3 | pass |
| [f7_stale_settings](f7_stale_settings/REPORT.md) | fenix7x | settings upgrade | 3 | pass |
| [vq_lock_pin_keypad](vq_lock_pin_keypad/REPORT.md) | venusq2 | lock confirmation | 4 | pass |
| [vq_wifi_without_radio](vq_wifi_without_radio/REPORT.md) | venusq2 | Wi-Fi/LTE | 3 | 1 of 3 failed |
| [e10_direct_wifi](e10_direct_wifi/REPORT.md) | edge1040 | Wi-Fi/LTE | 4 | pass |
| [e10_lock_pin_layout](e10_lock_pin_layout/REPORT.md) | edge1040 | lock confirmation | 4 | pass |
| [fr_lock_pin_wheel](fr_lock_pin_wheel/REPORT.md) | fr255 | lock confirmation | 5 | pass |
| [i2_https_entities](i2_https_entities/REPORT.md) | instinct2x | low memory | 3 | pass |
| [i2_http_rejected](i2_http_rejected/REPORT.md) | instinct2x | loopback http | 4 | pass |
| [i2_timers_rapid_actions](i2_timers_rapid_actions/REPORT.md) | instinct2x | timers (#101) | 3 | pass |
| [i2_phone_lost](i2_phone_lost/REPORT.md) | instinct2x | waiting for the phone | 8 | pass |
| [va3_entities_and_timers](va3_entities_and_timers/REPORT.md) | vivoactive3 | timers (#101) | 4 | pass |

**22 of 26 scenarios pass**, 112 individual checks, 8 of them failing.

Not passing in this run: f7_connection_wait, f7_wifi_offer_and_cancel, f7_wifi_confirm_starts_sync, vq_wifi_without_radio.

Every one of them changes the phone's connection while the widget is already running, and the
simulator's menus are unreliable at that moment: the Settings menu does not open, or the state
silently does not take. Each passed in an earlier run of this suite, with screenshots. The checks
that still pass inside them cover the waiting screen appearing and nothing being sent without a
phone, the widget staying open, the entities loading over https, cancelling the Wi-Fi/LTE question
sending nothing, and no crash.

What is therefore not covered automatically right now: the refresh that follows the phone coming
back, and the full Wi-Fi/LTE question-to-sync path on a watch. Both were seen working earlier.
