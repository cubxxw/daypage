const DATE_PARTS = new Intl.DateTimeFormat("en-CA", {
  timeZone: "UTC",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en", { timeZone }).format();
    return true;
  } catch {
    return false;
  }
}

export function normalizeTimeZone(value: unknown): string {
  return typeof value === "string" && isValidTimeZone(value) ? value : "UTC";
}

export function localDate(date: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: normalizeTimeZone(timeZone),
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

export function localHour(date: Date, timeZone: string): number {
  const hour = new Intl.DateTimeFormat("en-US", {
    timeZone: normalizeTimeZone(timeZone),
    hour: "2-digit",
    hourCycle: "h23",
  })
    .formatToParts(date)
    .find((part) => part.type === "hour")?.value;
  return Number(hour ?? "0");
}

export function addCalendarDays(dateString: string, days: number): string {
  const [year, month, day] = dateString.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day + days, 12));
  return DATE_PARTS.format(date);
}

export function isoWeekStart(dateString: string): string {
  const [year, month, day] = dateString.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day, 12));
  const weekday = date.getUTCDay() || 7;
  date.setUTCDate(date.getUTCDate() - weekday + 1);
  return DATE_PARTS.format(date);
}

export function localTimeLabel(date: Date, timeZone: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: normalizeTimeZone(timeZone),
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(date);
}

export function zonedLocalDateTimeToUtc(
  dateString: string,
  time: string,
  timeZone: string,
): Date {
  const [year, month, day] = dateString.split("-").map(Number);
  const [hour, minute] = time.split(":").map(Number);
  const desired = Date.UTC(year, month - 1, day, hour, minute, 0, 0);
  let candidate = new Date(desired);
  const zone = normalizeTimeZone(timeZone);
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: zone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  for (let iteration = 0; iteration < 4; iteration += 1) {
    const parts = Object.fromEntries(
      formatter.formatToParts(candidate).map((part) => [part.type, part.value]),
    );
    const represented = Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour),
      Number(parts.minute),
      Number(parts.second),
    );
    const correction = desired - represented;
    if (correction === 0) break;
    candidate = new Date(candidate.getTime() + correction);
  }
  return candidate;
}
