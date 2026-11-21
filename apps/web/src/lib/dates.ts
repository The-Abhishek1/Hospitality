export const addDays = (d: string, n: number) => {
  const t = new Date(`${d}T00:00:00Z`);
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
};

// Today's date in the property's own timezone (YYYY-MM-DD).
export const todayIn = (tz: string) => new Date().toLocaleDateString("en-CA", { timeZone: tz });

// Postgres daterange text "[2027-03-10,2027-03-12)" -> [from, to)
export const parseRange = (r: string): [string, string] => {
  const m = /\[(\d{4}-\d\d-\d\d),(\d{4}-\d\d-\d\d)\)/.exec(r);
  return m ? [m[1], m[2]] : ["", ""];
};
