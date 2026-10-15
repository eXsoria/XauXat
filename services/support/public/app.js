'use strict';
const $ = id => document.getElementById(id);
let policy, pending, tracked, pendingFollowup;
const bytesToToken = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
const privateReceipt = () => pending.id + '.' + pending.secret;
async function api(path, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30000);
  try {
    const response = await fetch(path, {...options, signal: controller.signal, cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer'});
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'The request could not be completed.');
    return data;
  } finally { clearTimeout(timer); }
}
function updateKind() {
  $('contact-options').hidden = $('kind').value === 'support';
  $('message-options').hidden = $('kind').value !== 'message_report';
}
$('kind').addEventListener('change', updateKind);
$('review').addEventListener('click', () => {
  const kind = $('kind').value;
  const payload = {kind, reason: $('reason').value, details: $('details').value.trim()};
  if (kind === 'support' && !payload.details) { $('request-status').textContent = 'Describe the problem before continuing.'; return; }
  if (kind !== 'support' && $('include-name').checked) payload.contactName = $('contact-name').value.trim();
  if (kind === 'message_report' && $('include-text').checked) payload.selectedText = $('selected-text').value.trim();
  if ((payload.contactName !== undefined && !payload.contactName) || (payload.selectedText !== undefined && !payload.selectedText)) { $('request-status').textContent = 'Complete the optional fields you chose to include.'; return; }
  pending = {...payload, version: 1, id: crypto.randomUUID(), secret: bytesToToken(crypto.getRandomValues(new Uint8Array(32))), consent: true, consentVersion: policy.consentVersion};
  $('preview').textContent = JSON.stringify(payload, null, 2);
  $('request-fields').disabled = true; $('review-panel').hidden = false; $('consent').checked = false; $('request-status').textContent = '';
});
$('edit').addEventListener('click', () => { pending = undefined; $('request-fields').disabled = false; $('review-panel').hidden = true; });
$('request-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (!pending || !$('consent').checked) { $('request-status').textContent = 'Review the data and confirm consent first.'; return; }
  const body = JSON.stringify(pending);
  if (new TextEncoder().encode(body).length > 24576) { $('request-status').textContent = 'This request is too large. Edit it and shorten the text.'; return; }
  $('send').disabled = true; $('edit').disabled = true; $('request-status').textContent = 'Sending…';
  $('receipt').value = privateReceipt(); $('receipt-panel').hidden = false;
  try {
    const ticket = await api('/api/v1/tickets', {method: 'POST', headers: {'Content-Type': 'application/json'}, body});
    $('reference').textContent = ticket.reference; $('receipt-title').textContent = 'Request received';
    $('review-panel').hidden = true; $('request-status').textContent = 'Keep your private receipt and use it to check for replies. Closing this page clears it from this page.';
  } catch (error) {
    $('receipt-title').textContent = 'Keep this receipt'; $('request-status').textContent = error.message + ' You can check the receipt before retrying; retry uses the same request identifier.';
    $('send').disabled = false;
    // Freeze the submitted payload after an uncertain response to avoid duplicates.
  }
});
$('copy').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('receipt').value); $('request-status').textContent = 'Private receipt copied. Store it safely.'; }
  catch { $('receipt').type = 'text'; $('receipt').select(); $('request-status').textContent = 'Select and copy the receipt, then store it safely.'; }
});
$('track-form').addEventListener('submit', async event => {
  if (pendingFollowup) { event.preventDefault(); $('track-status').textContent = 'Retry the pending message before changing receipts.'; return; }
  event.preventDefault(); const match = /^([0-9a-fA-F-]{36})\.([A-Za-z0-9_-]{43})$/.exec($('track-receipt').value.trim());
  $('replies').replaceChildren(); $('followup-form').hidden = true; tracked = undefined;
  if (!match) { $('track-status').textContent = 'Paste the complete private receipt.'; return; }
  $('track-status').textContent = 'Checking…';
  try {
    const ticket = await api('/api/v1/tickets/' + match[1].toLowerCase(), {headers: {Authorization: 'Bearer ' + match[2]}});
    tracked = {id: match[1].toLowerCase(), secret: match[2]}; $('followup-form').hidden = false;
    $('track-status').textContent = ticket.reference + ' · ' + ticket.status + ' · Expires ' + new Date(ticket.expiresAt * 1000).toLocaleDateString();
    for (const reply of ticket.replies) { const p = document.createElement('p'); p.textContent = (reply.sender === 'support' ? 'XauXat support' : 'You') + ' · ' + new Date(reply.createdAt * 1000).toLocaleString() + ' · ' + reply.text; $('replies').append(p); }
    if (!ticket.replies.length) $('replies').textContent = 'No reply yet. You can check again later.';
  } catch (error) { $('track-status').textContent = error.message; }
});
$('followup-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (!tracked || !$('followup-consent').checked || !policy) { $('track-status').textContent = 'Review the text and confirm consent first.'; return; }
  if (!pendingFollowup) pendingFollowup = {id: crypto.randomUUID(), text: $('followup-text').value.trim(), consent: true, consentVersion: policy.consentVersion};
  const body = JSON.stringify(pendingFollowup);
  if (!pendingFollowup.text || new TextEncoder().encode(body).length > 24576) { pendingFollowup = undefined; $('track-status').textContent = 'Enter a shorter description.'; return; }
  $('followup-send').disabled = true; $('followup-text').disabled = true; $('followup-consent').disabled = true;
  $('track-receipt').disabled = true;
  try {
    await api('/api/v1/tickets/' + tracked.id + '/messages', {method: 'POST', headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + tracked.secret}, body});
    pendingFollowup = undefined; $('track-receipt').disabled = false; $('followup-text').value = ''; $('followup-text').disabled = false; $('followup-consent').checked = false; $('followup-consent').disabled = false;
    $('track-status').textContent = 'Additional information received. Check the receipt again to refresh the conversation.';
  } catch (error) { $('track-status').textContent = error.message + ' Retry sends the same message.'; }
  finally { $('followup-send').disabled = false; }
});
api('/api/v1/policy').then(value => { policy = value; $('request-fields').disabled = false; }).catch(() => { $('request-status').textContent = 'The form is unavailable. Use the official contact address above.'; });
updateKind();
