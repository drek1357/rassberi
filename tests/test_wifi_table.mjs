import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const installerPath = process.argv[2] ?? new URL('../install.sh', import.meta.url);
const source = await readFile(installerPath, 'utf8');
const scanStart = source.indexOf('async function scanWifi()');
const connectStart = source.indexOf('async function connectWifi(', scanStart);
const forceScanStart = source.indexOf('async function forceScan()', connectStart);
assert(scanStart >= 0 && connectStart > scanStart && forceScanStart > connectStart,
  'Could not locate the Wi-Fi table functions in install.sh');

const functions = source.slice(scanStart, forceScanStart) + '\nexport { scanWifi, connectWifi };\n';
const moduleDirectory = await mkdtemp(join(tmpdir(), 'buddy-wifi-tests-'));
const modulePath = join(moduleDirectory, 'wifi-functions.mjs');
await writeFile(modulePath, functions, 'utf8');
const { scanWifi, connectWifi } = await import(pathToFileURL(modulePath).href);
await rm(moduleDirectory, { recursive: true, force: true });

class Element {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.listeners = {};
    this.style = {};
    this.value = '';
    this._textContent = '';
  }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...children) { this.children = children; this._textContent = ''; }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  set textContent(value) { this._textContent = String(value); this.children = []; }
  get textContent() { return this._textContent; }
}

const wifiBox = new Element('div');
const passwordFields = new Map();
globalThis.document = {
  getElementById(id) { return id === 'wifi-list' ? wifiBox : passwordFields.get(id) ?? null; },
  createElement(tag) { return new Element(tag); }
};
globalThis.alert = () => {};
globalThis.updateStatus = async () => {};

const walk = (element) => [element, ...element.children.flatMap(walk)];
let payload = { networks: [
  { ssid: '<img src=x onerror=alert(1)>', signal: '<script>', security: '<svg>', in_use: true },
  { ssid: 'Open & Cafe', signal: 60, security: '--', in_use: false },
  { ssid: 'Cafe 100% + Київ', signal: 71, security: 'WPA2', in_use: false }
] };
globalThis.fetch = async () => ({ json: async () => payload });
await scanWifi();

let nodes = walk(wifiBox.children[0]);
assert.equal(wifiBox.children[0].tag, 'table');
assert.equal(nodes.filter((node) => node.tag === 'th').length, 6);
assert(nodes.some((node) => node.tag === 'b' && node.textContent === '<img src=x onerror=alert(1)>'));
assert(nodes.some((node) => node.tag === 'td' && node.textContent === '<script>%'));
assert(nodes.some((node) => node.tag === 'td' && node.textContent === '<svg>'));
assert.equal(nodes.filter((node) => node.tag === 'img' || node.tag === 'script' || node.tag === 'svg').length, 0);
assert(nodes.some((node) => node.tag === 'input' && node.type === 'password'));
assert(nodes.some((node) => node.tag === 'td' && node.textContent === '-'));
assert.equal('innerHTML' in wifiBox, false);

let postBody;
let postCount = 0;
globalThis.fetch = async (_url, options = {}) => {
  if (options.body) {
    postCount++;
    postBody = JSON.parse(options.body);
  }
  return { json: async () => ({ message: 'ok' }) };
};
passwordFields.set('pass-2', Object.assign(new Element('input'), { value: 'secret' }));
await connectWifi('Cafe 100% + Київ', false, 2);
assert.equal(postBody.ssid, 'Cafe 100% + Київ', 'Percent signs and Unicode must remain unchanged');
assert.equal(postBody.password, 'secret');
await connectWifi('Open & Cafe', true, 1);
assert.equal(postBody.ssid, 'Open & Cafe');
assert.equal(postBody.password, '');

const hostileRow = nodes.find((node) => node.tag === 'tr' &&
  node.children[0]?.children[0]?.textContent === '<img src=x onerror=alert(1)>');
assert(hostileRow, 'The hostile SSID must remain a normal table row');
passwordFields.set('pass-0', Object.assign(new Element('input'), { value: 'secure-pass' }));
await hostileRow.children[5].children[0].listeners.click();
assert.equal(postBody.ssid, '<img src=x onerror=alert(1)>');
assert.equal(postBody.password, 'secure-pass');
const countBeforeEmptyPassword = postCount;
passwordFields.set('pass-2', Object.assign(new Element('input'), { value: '' }));
await connectWifi('Cafe 100% + Київ', false, 2);
assert.equal(postCount, countBeforeEmptyPassword, 'Empty secured-network passwords must not be sent');

payload = { networks: [] };
globalThis.fetch = async () => ({ json: async () => payload });
await scanWifi();
assert.equal(wifiBox.textContent, 'Мереж не знайдено.');
payload = { networks: 'malformed' };
await scanWifi();
assert.equal(wifiBox.textContent, 'Мереж не знайдено.');
globalThis.fetch = async () => { throw new Error('offline'); };
await scanWifi();
assert.equal(wifiBox.textContent, 'Помилка сканування.');

console.log('Wi-Fi table and connect scenarios passed.');

