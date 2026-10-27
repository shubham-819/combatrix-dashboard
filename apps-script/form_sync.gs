// Sends new "Contact Information (Responses)" rows to Supabase.
// Runs on every form submit, plus once a day around 10 AM IST as a catch-up.
// Supabase only imports responses newer than the last form timestamp it saw, so re-sending
// old rows is harmless and deleting or sorting rows is safe.
//
// One-time setup:
//   1. Project Settings -> Script Properties -> add SYNC_SECRET (value from the setup notes).
//   2. Run installTriggers once and approve the permissions.

const SUPABASE_URL = 'https://ucaulmnmpjxhdmzsfsdi.supabase.co';
const SUPABASE_KEY = 'sb_publishable_cQGg1RbRkRjRK7-FNCf9tA_HJTF6J6F'; // public key, same as the dashboard
const SPREADSHEET_ID = '1T42mo4XFHJvzP9xMsNtIhe8pSVfcMRpQDdRqj8ymaHc';
const SHEET_NAME = 'Sheet1';

// Column positions (0 = column A).
const COL = { timestamp: 0, name: 1, email: 2, emergencyName: 6, emergencyPhone: 8, phone: 11, phoneAlt: 12 };

function syncToSupabase() {
  const secret = PropertiesService.getScriptProperties().getProperty('SYNC_SECRET');
  if (!secret) throw new Error('Add the SYNC_SECRET script property first.');

  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const ss = SpreadsheetApp.openById(SPREADSHEET_ID);
    const sheet = ss.getSheetByName(SHEET_NAME) || ss.getSheets()[0];
    const values = sheet.getDataRange().getValues().slice(1); // skip header

    const rows = values
      .map(v => ({
        ts: v[COL.timestamp] instanceof Date ? v[COL.timestamp].toISOString() : '',
        date: v[COL.timestamp] instanceof Date
          ? Utilities.formatDate(v[COL.timestamp], 'Asia/Kolkata', 'yyyy-MM-dd') : '',
        name: String(v[COL.name] || ''),
        email: String(v[COL.email] || ''),
        phone: String(v[COL.phone] || v[COL.phoneAlt] || ''),
        emergency_name: String(v[COL.emergencyName] || ''),
        emergency_phone: String(v[COL.emergencyPhone] || ''),
      }))
      .filter(r => r.name || r.email);

    const res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/combatrix_sync_form_rows', {
      method: 'post',
      contentType: 'application/json',
      headers: { apikey: SUPABASE_KEY },
      payload: JSON.stringify({ p_secret: secret, p_rows: rows }),
      muteHttpExceptions: true,
    });
    const body = res.getContentText();
    if (res.getResponseCode() !== 200 || body.indexOf('"error"') !== -1) {
      throw new Error('Supabase sync failed (' + res.getResponseCode() + '): ' + body);
    }
    console.log('Synced: ' + body);
  } finally {
    lock.releaseLock();
  }
}

// Run once. Replaces only this script's own sync triggers.
function installTriggers() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'syncToSupabase')
    .forEach(t => ScriptApp.deleteTrigger(t));

  ScriptApp.newTrigger('syncToSupabase')
    .forSpreadsheet(SPREADSHEET_ID).onFormSubmit().create();
  ScriptApp.newTrigger('syncToSupabase')
    .timeBased().everyDays(1).atHour(10).inTimezone('Asia/Kolkata').create();
}
