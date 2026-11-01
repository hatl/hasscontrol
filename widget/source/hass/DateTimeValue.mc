using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Hass;
using Utils;

// Home Assistant's date and time entities (TYPE_DATETIME, see
// Entity.detectExtendedType()) as values the watch can show, edit and send:
//
//   input_datetime  "2026-12-24 18:00:00", "2026-07-01" or "06:30:00" -
//                   whichever of has_date/has_time the helper was set up
//                   with. Set with input_datetime.set_datetime and exactly
//                   the key it has: "datetime", "date" or "time" - any other
//                   one is an error.
//   date            "2026-07-01", set with date.set_value and "date".
//   time            "06:30:00", set with time.set_value and "time".
//   datetime        ISO 8601 with a time zone, in practice UTC:
//                   "2026-11-01T13:30:00+00:00". Set with datetime.set_value
//                   and "datetime", which takes any time zone. Shown and
//                   edited in the watch's local time, and sent with the
//                   watch's own offset ("2026-11-01T14:30:00+01:00").
//
// All of them can also be "unknown" or "unavailable".
//
// A value is passed around as "fields": [year, month, day, hour (0-23),
// minute], indexed by YEAR ... MINUTE. Seconds are dropped, and sent as 00.
//
// The time zone arithmetic is plain integer arithmetic on day numbers
// (Howard Hinnant's days_from_civil/civil_from_days) with the watch's
// current UTC offset, rather than Time.Gregorian.moment(): what time zone
// moment() and info() assume is easy to get wrong, and nothing here could
// be checked on a device. The current offset is used for every date, so a
// datetime on the other side of a daylight saving change is shown - and
// sent - one hour off from the wall clock time it will have then. Shown and
// sent the same way, it still round-trips unchanged.
//
// :fullmem only, see monkey.jungle. The 64 KB tier shows these entities
// read-only, trimmed but not converted (Entity.getDisplayValue()).
(:fullmem)
module DateTimeValue {
  // What an entity holds: a date, a time of day, or both. Bits, so that
  // `mode & MODE_DATE` tells whether there is a date.
  const MODE_DATE = 1;
  const MODE_TIME = 2;
  const MODE_BOTH = 3;

  // Indexes into fields. _parse() appends the state's UTC offset (in
  // seconds, or null) as OFFSET.
  enum {
    YEAR,
    MONTH,
    DAY,
    HOUR,
    MINUTE,
    OFFSET
  }

  // The years the editor offers (DateTimeEditView.step()).
  const YEAR_MIN = 1970;
  const YEAR_MAX = 2099;

  // The last UTC offset written to the debug log, see _localOffset().
  var _loggedOffset = null;

  // MODE_DATE, MODE_TIME or MODE_BOTH. date, time and datetime have a fixed
  // one. An input_datetime has whichever of a date and a time it was set up
  // with, and its state shows which: "-" in it means a date, ":" a time.
  // The mode is derived from that each time, never stored; a state without
  // either ("unknown", "unavailable", or none yet) counts as both.
  function modeOf(entity) {
    var domain = entity.getServiceDomain();

    if ("date".equals(domain)) {
      return MODE_DATE;
    }
    if ("time".equals(domain)) {
      return MODE_TIME;
    }

    var state = entity.getSensorValue();

    if ("input_datetime".equals(domain) && state != null) {
      var hasDate = state.find("-") != null;
      var hasTime = state.find(":") != null;

      if (hasDate && !hasTime) {
        return MODE_DATE;
      }
      if (hasTime && !hasDate) {
        return MODE_TIME;
      }
    }

    return MODE_BOTH;
  }

  // The service that sets `entity`'s value.
  function serviceName(entity) {
    return "input_datetime".equals(entity.getServiceDomain()) ? "set_datetime" : "set_value";
  }

  // The service call's parameters that set `entity` to `fields` (local
  // time): exactly the one key `mode` - the entity's - names. Sending a key
  // the entity does not have would fail; Hass.setDateTimeValue() makes
  // sure the mode is still the entity's.
  function serviceParams(entity, fields, mode) {
    if (mode == MODE_DATE) {
      return { "date" => formatDate(fields) };
    }
    if (mode == MODE_TIME) {
      return { "time" => _clock(fields) };
    }
    if (_isZoned(entity)) {
      return { "datetime" => formatDate(fields) + "T" + _clock(fields) + _formatOffset(_localOffset()) };
    }
    return { "datetime" => formatDate(fields) + " " + _clock(fields) };
  }

  // The state Home Assistant reports for `entity` once `params` (see
  // serviceParams()) has been set: what was sent - only a datetime.* value
  // is converted to UTC, as Home Assistant keeps those. Null when `params`
  // has no value that can be read.
  function reportedState(entity, params) {
    var value = params["datetime"];

    if (value != null && _isZoned(entity)) {
      var parts = _parse(value);

      if (!_isComplete(parts, MODE_BOTH)) {
        return null;
      }

      var utc = _shift(parts, -_offsetOf(parts) / 60);
      return formatDate(utc) + "T" + _clock(utc) + "+00:00";
    }

    if (value == null) {
      value = params["date"];
    }
    if (value == null) {
      value = params["time"];
    }
    return value;
  }

  // What the list and the card show: "2026-11-01", "14:30" (or "2:30 PM"
  // on a watch set to the 12-hour clock) or "2026-11-01 14:30", datetime.*
  // in the watch's local time. A state that cannot be read ("unknown",
  // "unavailable") is shown as it is.
  function displayText(entity) {
    var state = entity.getSensorValue();
    var mode = modeOf(entity);
    var parts = _parse(state);

    if (!_isComplete(parts, mode)) {
      return state;
    }

    if (_isZoned(entity)) {
      parts = _toLocal(parts);
    }

    return format(mode, parts);
  }

  // The fields the editor starts with: `entity`'s value in local time, and
  // now (local) for whatever the state does not have or that cannot be
  // read. A value outside the years the editor offers becomes the nearest
  // end of them as a whole - YEAR_MIN-01-01 00:00 or YEAR_MAX-12-31 23:59 -
  // as clamping just its year would move it by years and could leave a
  // 29 February in a year without one.
  function initialFields(entity) {
    var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
    var fields = [now.year, now.month, now.day, now.hour, now.min];
    var state = entity.getState() == Hass.STATE_SENSOR ? entity.getSensorValue() : null;
    var parts = _parse(state);

    if (_isZoned(entity)) {
      // Only a complete date and time can be moved to another time zone.
      parts = _isComplete(parts, MODE_BOTH) ? _toLocal(parts) : [null, null, null, null, null];
    }

    for (var i = YEAR; i <= MINUTE; i++) {
      if (parts[i] != null) {
        fields[i] = parts[i];
      }
    }

    if (fields[YEAR] < YEAR_MIN) {
      return [YEAR_MIN, 1, 1, 0, 0];
    }
    if (fields[YEAR] > YEAR_MAX) {
      return [YEAR_MAX, 12, 31, 23, 59];
    }

    return fields;
  }

  // `fields` as text for people, with the parts `mode` names: see
  // displayText().
  function format(mode, fields) {
    var text = "";

    if ((mode & MODE_DATE) != 0) {
      text = formatDate(fields);
    }

    if ((mode & MODE_TIME) != 0) {
      if (text.length() > 0) {
        text += " ";
      }
      text += formatTime(fields[HOUR], fields[MINUTE], System.getDeviceSettings().is24Hour);
    }

    return text;
  }

  // "2026-11-01".
  function formatDate(fields) {
    return fields[YEAR].format("%04d") + "-" + fields[MONTH].format("%02d") + "-" + fields[DAY].format("%02d");
  }

  // "14:30", or "2:30 PM" for the 12-hour clock.
  function formatTime(hour, minute, is24Hour) {
    if (is24Hour) {
      return hour.format("%02d") + ":" + minute.format("%02d");
    }

    return hour12(hour).toString() + ":" + minute.format("%02d") + (hour < 12 ? " AM" : " PM");
  }

  // An hour of the day (0-23) on the 12-hour clock: 1-12.
  function hour12(hour) {
    var h = hour % 12;
    return h == 0 ? 12 : h;
  }

  function daysInMonth(year, month) {
    if (month == 2) {
      return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28;
    }
    if (month == 4 || month == 6 || month == 9 || month == 11) {
      return 30;
    }
    return 31;
  }

  // "HH:MM:00", the time as the services take it.
  function _clock(fields) {
    return fields[HOUR].format("%02d") + ":" + fields[MINUTE].format("%02d") + ":00";
  }

  // datetime.* is the one domain whose state has a time zone.
  function _isZoned(entity) {
    return "datetime".equals(entity.getServiceDomain());
  }

  // Whether `parts` has everything `mode` asks for.
  function _isComplete(parts, mode) {
    return ((mode & MODE_DATE) == 0 || parts[YEAR] != null)
      && ((mode & MODE_TIME) == 0 || parts[HOUR] != null);
  }

  // Reads a state: "2026-12-24 18:00:00", "2026-07-01", "06:30:00" or
  // "2026-11-01T13:30:00+00:00" (also with a fraction of a second, or "Z").
  // Returns [year, month, day, hour, minute, offset]: the date or the time
  // is null where the text has none or it is not valid; the offset is in
  // seconds east of UTC, null where there is none.
  function _parse(text) {
    var parts = [null, null, null, null, null, null];

    if (text == null) {
      return parts;
    }

    var chars = text.toCharArray();
    var size = chars.size();
    var at = 0;

    // A date comes first, followed by " " or "T" where a time follows.
    if (size >= 10 && chars[4] == '-' && chars[7] == '-') {
      var year = _digits(chars, 0, 4);
      var month = _digits(chars, 5, 2);
      var day = _digits(chars, 8, 2);

      if (
        year != null && month != null && day != null
        && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth(year, month)
      ) {
        parts[YEAR] = year;
        parts[MONTH] = month;
        parts[DAY] = day;
      }

      at = 11;
    }

    if (size >= at + 5 && chars[at + 2] == ':') {
      var hour = _digits(chars, at, 2);
      var minute = _digits(chars, at + 3, 2);

      if (hour != null && minute != null && hour <= 23 && minute <= 59) {
        parts[HOUR] = hour;
        parts[MINUTE] = minute;

        // Past the seconds and any fraction of them, to the offset.
        at += 5;
        while (at < size && (chars[at] == ':' || chars[at] == '.' || _digits(chars, at, 1) != null)) {
          at++;
        }

        parts[OFFSET] = _parseOffset(chars, at);
      }
    }

    return parts;
  }

  // The UTC offset at `at` in seconds: "Z", "+01:00" or "-05:30". Null
  // when there is none.
  function _parseOffset(chars, at) {
    var size = chars.size();

    if (at >= size) {
      return null;
    }

    if (chars[at] == 'Z') {
      return 0;
    }

    if (size < at + 6 || chars[at + 3] != ':' || (chars[at] != '+' && chars[at] != '-')) {
      return null;
    }

    var hours = _digits(chars, at + 1, 2);
    var minutes = _digits(chars, at + 4, 2);

    if (hours == null || minutes == null) {
      return null;
    }

    var seconds = hours * 3600 + minutes * 60;
    return chars[at] == '-' ? -seconds : seconds;
  }

  // The number written with `count` digits from `start`, or null if one of
  // them is not a digit. Parsed by hand: String.toNumber() would have to
  // be cut out first, and it is not clear how it takes a leading zero.
  function _digits(chars, start, count) {
    if (start + count > chars.size()) {
      return null;
    }

    var value = 0;

    for (var i = start; i < start + count; i++) {
      var digit = chars[i].toNumber() - 48; // '0'

      if (digit < 0 || digit > 9) {
        return null;
      }

      value = value * 10 + digit;
    }

    return value;
  }

  // A state's own offset; a datetime.* state without one is UTC.
  function _offsetOf(parts) {
    return parts[OFFSET] != null ? parts[OFFSET] : 0;
  }

  // A complete datetime.* value, from its own offset to the watch's.
  function _toLocal(parts) {
    return _shift(parts, _localOffset() / 60 - _offsetOf(parts) / 60);
  }

  // The watch's UTC offset in seconds (east positive). Connect IQ documents
  // ClockTime.timeZoneOffset only as "the time offset from UTC"; it is
  // taken to include daylight saving time already (ClockTime.dst reports
  // that part separately), so it is used as it is. Logged when it differs
  // from the last one logged, i.e. once in practice.
  function _localOffset() {
    var offset = System.getClockTime().timeZoneOffset;

    if (offset != _loggedOffset) {
      _loggedOffset = offset;
      Utils.debugLog("DateTimeValue: UTC offset ", offset, " s");
    }

    return offset;
  }

  // "+01:00", "-05:30".
  function _formatOffset(seconds) {
    var minutes = (seconds < 0 ? -seconds : seconds) / 60;
    return (seconds < 0 ? "-" : "+") + (minutes / 60).format("%02d") + ":" + (minutes % 60).format("%02d");
  }

  // `parts` moved by `minutes` (either sign), as fields. Counted in
  // minutes, not seconds: seconds since 1970 pass the 32-bit Number range
  // in 2038.
  function _shift(parts, minutes) {
    var total = _daysFromCivil(parts[YEAR], parts[MONTH], parts[DAY]) * 1440
      + parts[HOUR] * 60 + parts[MINUTE] + minutes;
    var days = total / 1440;

    // Rounded down, not towards zero: before 1970 the remainder would be
    // negative.
    if (total < 0 && days * 1440 != total) {
      days -= 1;
    }

    var rest = total - days * 1440;
    var date = _civilFromDays(days);

    return [date[0], date[1], date[2], rest / 60, rest % 60];
  }

  // Days since 1970-01-01 of a date in the proleptic Gregorian calendar
  // (Hinnant's days_from_civil). The year starts in March, so that the leap
  // day is the last day of it.
  function _daysFromCivil(year, month, day) {
    if (month <= 2) {
      year -= 1;
    }

    var era = (year >= 0 ? year : year - 399) / 400;
    var yearOfEra = year - era * 400;                                       // 0-399
    var dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1; // 0-365
    var dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;  // 0-146096

    return era * 146097 + dayOfEra - 719468;
  }

  // [year, month, day] of a day count since 1970-01-01 (Hinnant's
  // civil_from_days).
  function _civilFromDays(days) {
    days += 719468;

    var era = (days >= 0 ? days : days - 146096) / 146097;
    var dayOfEra = days - era * 146097;                                     // 0-146096
    var yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365; // 0-399
    var dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100); // 0-365
    var monthIndex = (5 * dayOfYear + 2) / 153;                             // 0-11, from March
    var day = dayOfYear - (153 * monthIndex + 2) / 5 + 1;
    var month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
    var year = yearOfEra + era * 400;

    return [month <= 2 ? year + 1 : year, month, day];
  }
}
