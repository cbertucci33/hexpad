import Foundation

/// Date and time strings for the Tools menu "Insert Date/Time" commands.
///
/// The short formats follow Notepad++'s conventions: the date is the locale's
/// short date (for example `3/4/2021` in `en_US`), the time is the locale's
/// short time (for example `5:06 AM`), and the combined format joins the two
/// with the locale's usual separator.
///
/// All functions are pure: the output depends only on the date, locale and
/// time zone passed in. None of them read the current clock, so callers decide
/// which instant to insert (normally `Date()` at the moment the menu item is
/// chosen).
///
/// ### Custom format patterns
///
/// `formatted(_:pattern:locale:timeZone:)` takes a Unicode date format pattern
/// (Unicode Technical Standard #35, "Date Field Symbol Table"). The pattern is
/// used literally, unlike a localized template, so `"yyyy-MM-dd"` always
/// produces year-month-day order. Common symbols:
///
/// | Symbol | Meaning                         | Example      |
/// | ------ | ------------------------------- | ------------ |
/// | `y`    | Year (`yy` = two digits)        | `2026`, `26` |
/// | `M`    | Month (`MM` padded, `MMM` short) | `3`, `03`, `Mar`, `March` |
/// | `d`    | Day of month (`dd` padded)      | `4`, `04`    |
/// | `E`    | Weekday (`EEEE` full)           | `Thu`, `Thursday` |
/// | `H`    | Hour 0–23 (`HH` padded)         | `5`, `05`    |
/// | `h`    | Hour 1–12 (`hh` padded)         | `5`, `05`    |
/// | `m`    | Minute (`mm` padded)            | `6`, `06`    |
/// | `s`    | Second (`ss` padded)            | `7`, `07`    |
/// | `S`    | Fractional second               | `123`        |
/// | `a`    | AM/PM marker                    | `AM`         |
/// | `z`    | Time zone name                  | `GMT`        |
/// | `Z`    | Time zone offset (`ZZZZZ` = `+00:00`) | `+0000` |
///
/// Repeat a symbol to change its width (for example `yyyy` for a four-digit
/// year). Wrap literal text in single quotes, such as `"yyyy'年'MM'月'"`; a
/// doubled quote (`''`) emits one apostrophe.
public enum DateTimeInsert {

    /// Returns the locale's short date, such as `3/4/2021` in `en_US`.
    public static func shortDate(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        string(from: date, dateStyle: .short, timeStyle: .none, locale: locale, timeZone: timeZone)
    }

    /// Returns the locale's short time, such as `5:06 AM` in `en_US`.
    public static func shortTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        string(from: date, dateStyle: .none, timeStyle: .short, locale: locale, timeZone: timeZone)
    }

    /// Returns the locale's short date and time joined by the locale's
    /// separator, such as `3/4/2021, 5:06 AM` in `en_US`.
    public static func shortDateTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        string(from: date, dateStyle: .short, timeStyle: .short, locale: locale, timeZone: timeZone)
    }

    /// Returns `date` formatted with a custom Unicode date format pattern.
    ///
    /// See the type documentation for the supported field symbols. Literal
    /// text can be quoted, and localized names (`MMMM`, `EEEE`, `a`) come from
    /// `locale`, while the calendar fields are resolved in `timeZone`.
    ///
    /// ```swift
    /// DateTimeInsert.formatted(date, pattern: "yyyy-MM-dd HH:mm:ss")
    /// // "2026-03-04 05:06:07"
    /// ```
    public static func formatted(
        _ date: Date,
        pattern: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    private static func string(
        from date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}
