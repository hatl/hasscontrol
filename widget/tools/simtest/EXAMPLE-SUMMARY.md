# Simulator results (branch claude/datetime-entities, 2026-11-02)

Latest result of every scenario. The date/time scenarios, the loader scenarios and the eight marked
with * ran on commit 59b5aa1; the others on the commit before the date/time work.

| scenario | device | feature | checks | result |
|---|---|---|---:|---|
| f7_loopback_http* | fenix7x | loopback http | 4 | pass |
| f7_http_uppercase | fenix7x | loopback http | 2 | pass |
| f7_http_localhost | fenix7x | loopback http | 2 | pass |
| f7_http_bad_host | fenix7x | loopback http | 4 | pass |
| f7_http_userinfo | fenix7x | loopback http | 4 | pass |
| f7_lock_no_confirmation* | fenix7x | lock confirmation | 1 | pass |
| f7_lock_yesno* | fenix7x | lock confirmation | 7 | pass |
| f7_lock_pin_ok | fenix7x | lock confirmation | 7 | pass |
| f7_lock_pin_wrong_and_lockout | fenix7x | lock confirmation | 10 | pass |
| f7_lock_pin_delete_and_leave | fenix7x | lock confirmation | 5 | pass |
| f7_lock_pin_not_set | fenix7x | lock confirmation | 2 | pass |
| f7_connection_wait* | fenix7x | waiting for the phone | 5 | pass |
| f7_wait_back_to_stored | fenix7x | waiting for the phone | 5 | pass |
| f7_wifi_offer_and_cancel* | fenix7x | Wi-Fi/LTE | 5 | pass |
| f7_wifi_confirm_starts_sync | fenix7x | Wi-Fi/LTE | 6 | pass |
| f7_timers_rapid_actions* | fenix7x | timers (#101) | 3 | pass |
| f7_stale_settings | fenix7x | settings upgrade | 3 | pass |
| vq_lock_pin_keypad | venusq2 | lock confirmation | 4 | pass |
| vq_wifi_without_radio | venusq2 | Wi-Fi/LTE | 3 | pass |
| e10_direct_wifi | edge1040 | Wi-Fi/LTE | 4 | pass |
| e10_lock_pin_layout | edge1040 | lock confirmation | 4 | pass |
| fr_lock_pin_wheel | fr255 | lock confirmation | 5 | pass |
| i2_https_entities* | instinct2x | low memory | 3 | pass |
| i2_http_rejected | instinct2x | loopback http | 4 | pass |
| i2_timers_rapid_actions* | instinct2x | timers (#101) | 3 | pass |
| i2_phone_lost | instinct2x | waiting for the phone | 8 | pass |
| va3_entities_and_timers | vivoactive3 | timers (#101) | 4 | pass |
| f7_dt_time_buttons | fenix7x | date and time | 21 | pass |
| f7_dt_date_clamps | fenix7x | date and time | 14 | pass |
| f7_dt_datetime_local | fenix7x | date and time | 15 | pass |
| f7_dt_input_datetime_time_only | fenix7x | date and time | 13 | pass |
| f7_dt_input_datetime_both | fenix7x | date and time | 13 | pass |
| f7_dt_input_datetime_date_only | fenix7x | date and time | 11 | pass |
| f7_dt_cancel | fenix7x | date and time | 20 | pass |
| f7_dt_hold_release | fenix7x | date and time | 10 | pass |
| f7_dt_offline_mode | fenix7x | date and time | 11 | pass |
| f7_dt_time_12h | fenix7x | date and time | 13 | pass |
| f7_dt_wifi_offer | fenix7x | date and time | 10 | pass |
| vq_dt_touch | venusq2 | date and time | 14 | pass |
| vq_dt_touch_field_tap | venusq2 | date and time | 11 | pass |
| e10_dt_touch | edge1040 | date and time | 14 | pass |
| fr_dt_buttons | fr255 | date and time | 21 | pass |
| i2_dt_readonly | instinct2x | date and time | 8 | pass |
| va3_dt_readonly | vivoactive3 | date and time | 9 | pass |
| f7_loader_back | fenix7x | loader back | 12 | pass |
| vq_loader_back | venusq2 | loader back | 13 | pass |

**46 of 46 scenarios pass.**
