// Test the actual ArkTS observer implementation with an in-memory NetworkKit.
// Node strips only TypeScript annotations; no OS networking or VPN is used.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { stripTypeScriptTypes } = require('node:module');
const root = resolve(__dirname, '../..');
const model = readFileSync(resolve(root, 'ohos/entry/src/main/ets/models/Network.ets'), 'utf8')
  .replace(/^import .*$/gm, '').replace('export class Network', 'class Network');
const manager = readFileSync(resolve(root, 'ohos/entry/src/main/ets/managers/NetworkManager.ets'), 'utf8')
  .replace(/^import .*$/gm, '').replace('export default class NetworkManager', 'class NetworkManager');
const load = new Function('connection', `${stripTypeScriptTypes(`${model}\n${manager}`)}\nreturn NetworkManager;`);

function fixture() {
  const state = { netId: 0, observers: [], messages: [], failRegistration: false, holdRegistration: false, registrations: [], snapshotCapabilities: [] };
  const connection = {
    NetCap: { NET_CAPABILITY_PORTAL: 17, NET_CAPABILITY_VALIDATED: 16 },
    getDefaultNetSync: () => ({ netId: state.netId }),
    getNetCapabilitiesSync: () => ({ bearerTypes: [1], networkCap: state.snapshotCapabilities }),
    getConnectionPropertiesSync: () => ({ interfaceName: 'test0', dnses: [], linkAddresses: [] }),
    createNetConnection: () => {
      const handlers = {};
      const observer = {
        on: (name, callback) => { handlers[name] = callback; },
        register: (callback) => {
          if (state.holdRegistration) state.registrations.push(callback);
          else queueMicrotask(() => callback(state.failRegistration ? new Error('registration failed') : undefined));
        },
        unregister: (callback) => { observer.unregisterCount++; queueMicrotask(() => callback()); },
        unregisterCount: 0,
        emit: (name, data) => handlers[name](data),
      };
      state.observers.push(observer);
      return observer;
    },
  };
  state.manager = new (load(connection))();
  state.subscribe = () => state.manager.subscribe((message) => state.messages.push(JSON.parse(message)));
  state.available = (id) => { state.netId = id; state.observers.at(-1).emit('netAvailable', { netId: id }); };
  state.capabilities = (id, caps, bearer = 1) => state.observers.at(-1).emit('netCapabilitiesChange', {
    netHandle: { netId: id }, netCap: { bearerTypes: [bearer], networkCap: caps },
  });
  state.properties = (id, address = '192.0.2.2') => state.observers.at(-1).emit('netConnectionPropertiesChange', {
    netHandle: { netId: id }, connectionProperties: {
      interfaceName: 'test0', dnses: [{ family: 1, address: '192.0.2.53' }],
      linkAddresses: [{ address: { address }, prefixLength: 24 }],
    },
  });
  return state;
}

test('same-DNS handoff and link changes reach native recovery, duplicates do not', async () => {
  const f = fixture(); await f.subscribe();
  f.available(1); f.capabilities(1, [16]); f.properties(1);
  const before = f.messages.length;
  f.properties(1); assert.equal(f.messages.length, before);
  f.available(2); f.capabilities(2, [16], 0); f.properties(2);
  assert.ok(f.messages.length > before);
  assert.deepEqual(f.messages.at(-1).dns, ['192.0.2.53:53']);
  assert.equal(f.messages.at(-1).online, true);
  const afterHandoff = f.messages.length;
  f.properties(2, '192.0.2.3'); assert.equal(f.messages.length, afterHandoff + 1);
  await f.manager.unsubscribe();
});

test('missing validation is not offline; only explicit portal capability is portal', async () => {
  const f = fixture(); await f.subscribe(); f.available(1); f.capabilities(1, []);
  assert.equal(f.messages.at(-1).online, true);
  assert.equal(f.messages.at(-1).captivePortal, false);
  assert.equal(f.messages.at(-1).validated, false);
  f.capabilities(1, [17]); assert.equal(f.messages.at(-1).captivePortal, true);
  f.capabilities(1, [16]); assert.equal(f.messages.at(-1).captivePortal, false);
  f.netId = 0; f.observers[0].emit('netLost', { netId: 1 });
  assert.equal(f.messages.at(-1).online, false);
  await f.manager.unsubscribe();
});

test('subscribe is idempotent and late callbacks cannot revive a stopped generation', async () => {
  const f = fixture(); await f.subscribe(); await f.subscribe();
  assert.equal(f.observers.length, 1); f.available(1);
  const stale = f.observers[0]; await f.manager.unsubscribe();
  assert.equal(stale.unregisterCount, 1);
  assert.equal(f.messages.at(-1).kind, 'network-stop');
  const stopped = f.messages.length;
  stale.emit('netLost', { netId: 1 }); assert.equal(f.messages.length, stopped);
  await f.subscribe(); assert.equal(f.observers.length, 2);
  stale.emit('netAvailable', { netId: 1 }); assert.equal(f.messages.length, stopped);
  f.available(1); assert.equal(f.messages.length, stopped + 1);
  await f.manager.unsubscribe(); await f.manager.unsubscribe();
  assert.equal(f.observers[1].unregisterCount, 1);
});

test('failed registration can be retried', async () => {
  const f = fixture(); f.failRegistration = true;
  await assert.rejects(f.subscribe(), /registration failed/);
  f.failRegistration = false; await f.subscribe();
  assert.equal(f.observers.length, 2); f.available(1);
  assert.equal(f.messages.at(-1).online, true);
  await f.manager.unsubscribe();
});


test('stop during pending register waits before unregister and ignores late events', async () => {
  const f = fixture(); f.holdRegistration = true;
  const registration = f.subscribe();
  const stopped = f.manager.unsubscribe();
  assert.equal(f.observers[0].unregisterCount, 0);
  f.registrations[0]();
  await registration; await stopped;
  assert.equal(f.observers[0].unregisterCount, 1);
  const count = f.messages.length; f.available(1);
  assert.equal(f.messages.length, count);
});


test('first-connect portal snapshot is available without waiting for network events or starting VPN', async () => {
  const f = fixture(); f.netId = 1; f.snapshotCapabilities = [17];
  const registration = f.subscribe();
  await f.manager.refreshSnapshot(); await registration;
  assert.equal(f.messages.at(-1).online, true);
  assert.equal(f.messages.at(-1).captivePortal, true);
  f.snapshotCapabilities = [16]; await f.manager.refreshSnapshot();
  assert.equal(f.messages.at(-1).captivePortal, false);
  await f.manager.unsubscribe();
});
