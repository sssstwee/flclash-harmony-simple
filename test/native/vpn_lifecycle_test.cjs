// Exercise actual VpnExtAbility lifecycle code using only in-memory API stubs.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { stripTypeScriptTypes } = require('node:module');
const source = readFileSync(resolve(__dirname, '../../ohos/entry/src/main/ets/extensionAbility/VpnExtAbility.ets'), 'utf8')
  .replace(/^import .*$/gm, '').replace(/export /g, '').replace('default class', 'class');
const code = stripTypeScriptTypes(source, { mode: 'transform' });
const load = new Function('m', `const {vpnExtension, VpnExtensionAbility, rpc, deviceInfo, util, startTUN, stopTun,
  forceGC, suspend, updateDns, quickSetup, setEventListener, invokeAction, AccessControlMode,
  ChunkedSender, ChunkedReader, PowerManager, NetworkManager, AbilityConstant} = m;\n${code}\nreturn VpnExtAbility;`);
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return {promise, resolve}; };
const tick = () => new Promise((resolve) => setImmediate(resolve));
function fixture() {
  const state = { connections: [], starts: 0, stops: 0, networkStarts: 0, networkStops: 0, recoveryStops: 0, invocations: [], snapshot: null, results: [] };
  const m = {
    VpnExtensionAbility: class { context = {}; },
    vpnExtension: { createVpnConnection: () => {
      const create = deferred(); const id = deferred();
      const connection = { create: () => create.promise, generateVpnId: () => id.promise,
        protect: () => Promise.resolve(), destroy: () => {
          connection.destroyed++;
          if (connection.holdDestroy) {
            const pending = deferred(); connection.pendingDestroys.push(pending); return pending.promise;
          }
          return Promise.resolve();
        },
        created: create, id, destroyed: 0, holdDestroy: false, pendingDestroys: [] };
      state.connections.push(connection); return connection;
    } },
    rpc: { RemoteObject: class {} }, deviceInfo: { sdkApiVersion: 20 }, util: {},
    startTUN: () => { state.starts++; }, stopTun: () => { state.stops++; },
    PowerManager: class { subscribe() {} unsubscribe() {} },
    NetworkManager: class {
      subscribed = false;
      subscribe() { if (!this.subscribed) { state.networkStarts++; this.subscribed = true; } return Promise.resolve(); }
      refreshSnapshot() { return state.snapshot?.promise ?? Promise.resolve(); }
      unsubscribe() { if (this.subscribed) { state.networkStops++; this.subscribed = false; } return Promise.resolve(); }
    },
    invokeAction: (callback, data) => { state.invocations.push(data); },
    updateDns: (value) => { if (JSON.parse(value).kind === 'recovery-stop') state.recoveryStops++; },
    ChunkedSender: class {}, ChunkedReader: class {}, AccessControlMode: {}, AbilityConstant: {},
  };
  state.ability = new (load(m))(); state.ability.onCreate({});
  state.ability.toVpnConfig = () => ({}); state.ability.toTunAddress = () => ''; state.ability.toTunDns = () => '';
  state.ability.sendResult = (_, value) => state.results.push(value);
  state.start = () => state.ability.handleStartService({enable: true, stack: 'test'}, 42, {});
  return state;
}

test('late create after stop cannot start TUN or observer; next start waits for cleanup', async () => {
  const f = fixture(); f.start(); const old = f.connections.at(-1);
  f.ability.handleStopService({}); f.start();
  assert.equal(f.connections.at(-1), old); // New create waits for stale cleanup.
  old.created.resolve(1); await tick();
  const fresh = f.connections.at(-1);
  assert.notEqual(fresh, old);
  assert.equal(f.starts, 0); assert.equal(f.networkStarts, 1); assert.equal(fresh.destroyed, 0);
  fresh.created.resolve(2); await tick();
  assert.equal(f.starts, 1); assert.equal(f.networkStarts, 1);
  f.ability.handleStopService({}); assert.equal(f.stops, 1);
});

test('destroy invalidates pending start and late VPN ID cannot resurrect stopped state', async () => {
  const pending = fixture(); pending.start(); const old = pending.connections.at(-1);
  pending.ability.onDestroy(); old.created.resolve(1); await tick();
  assert.equal(pending.starts, 0); assert.equal(pending.networkStarts, 1);
  const active = fixture(); active.start(); const connection = active.connections.at(-1);
  connection.created.resolve(1); await tick(); active.ability.onDestroy();
  connection.id.resolve('late-id'); await tick();
  assert.equal(active.stops, 1); assert.equal(active.ability.vpnId, undefined); assert.equal(active.ability.runTime, 0);
  active.start(); assert.equal(active.starts, 1);
});

test('stop immediately after TUN start works before asynchronous VPN ID arrives', async () => {
  const f = fixture(); f.start(); const connection = f.connections.at(-1);
  connection.created.resolve(1); await tick();
  assert.equal(f.ability.vpnId, undefined);
  f.ability.handleStopService({}); assert.equal(f.stops, 1);
  connection.id.resolve('late-id'); await tick(); assert.equal(f.ability.vpnId, undefined);
});


test('repeated stop waits for every teardown, including an older slow destroy', async () => {
  const f = fixture(); f.start(); const connection = f.connections.at(-1);
  connection.created.resolve(1); await tick(); connection.holdDestroy = true;
  f.ability.handleStopService({}); f.ability.handleStopService({}); f.start();
  assert.equal(connection.pendingDestroys.length, 2);
  connection.pendingDestroys[1].resolve(); await tick();
  assert.equal(f.connections.at(-1), connection);
  connection.pendingDestroys[0].resolve(); await tick();
  assert.notEqual(f.connections.at(-1), connection);
  assert.equal(f.starts, 1);
});


test('physical network observation precedes first preflight and survives user stop', async () => {
  const f = fixture();
  assert.equal(f.networkStarts, 1); assert.equal(f.starts, 0);
  f.ability.handleStopService({}); await tick();
  assert.equal(f.recoveryStops, 1); assert.equal(f.networkStops, 0);
  f.ability.onDestroy(); assert.equal(f.networkStops, 1);
});


test('network-state RPC waits for the native snapshot before forwarding to core', async () => {
  const f = fixture(); f.snapshot = deferred();
  const action = JSON.stringify({ method: 'asyncTestDelay', data: JSON.stringify({ 'network-state': true }) });
  f.ability.handleInvokeAction(action, {});
  assert.equal(f.invocations.length, 0); assert.equal(f.starts, 0);
  f.snapshot.resolve(); await tick();
  assert.deepEqual(f.invocations, [action]);
});
