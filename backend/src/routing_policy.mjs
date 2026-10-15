import { parse, stringify } from 'yaml';
import policy from '../routing-policy.json' with { type: 'json' };

export { policy as routingPolicy };
const blocked = new Set(['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'GLOBAL']);
const localTypes = new Set(['direct', 'reject', 'reject-drop', 'pass']);
const aiName = name => /🤖|智能|(?:^|[^a-z])ai(?:[^a-z]|$)|openai|chatgpt|claude|gemini|gpt/i.test(name);

function graph(config) {
  const nodes = new Set((config.proxies ?? []).filter(node => !localTypes.has(node.type)).map(node => node.name));
  const groups = new Map((config['proxy-groups'] ?? []).map(group => [group.name, group]));
  const providers = new Set(Object.keys(config['proxy-providers'] ?? {}));
  function hasProxy(name, visited = new Set()) {
    if (blocked.has(name) || visited.has(name)) return false;
    if (nodes.has(name)) return true;
    const group = groups.get(name);
    if (!group || group.type === 'relay') return false;
    if ((group.use ?? []).some(name => providers.has(name)) ||
        (group['include-all'] && (nodes.size || providers.size)) ||
        (group['include-all-proxies'] && nodes.size) ||
        (group['include-all-providers'] && providers.size)) return true;
    return (group.proxies ?? []).some(child => hasProxy(child, new Set([...visited, name])));
  }
  return { groups, hasProxy };
}

function defaultTarget(config) {
  const { groups, hasProxy } = graph(config);
  for (const rule of [...(config.rules ?? [])].reverse()) {
    const [type, target] = rule.split(',').map(value => value.trim());
    if (['MATCH', 'FINAL'].includes(type.toUpperCase()) && groups.has(target) && hasProxy(target)) return target;
  }
  return [...groups].find(([name, group]) => name !== policy.aiGroup && !group.hidden && hasProxy(name))?.[0];
}

function filterAiGroups(config) {
  const aiGroups = (config['proxy-groups'] ?? []).filter(group => group.name === policy.aiGroup || aiName(group.name));
  for (const group of aiGroups) {
    group.proxies = (group.proxies ?? []).filter(name => !/warp/i.test(name));
    if (!group.proxies.length) throw new Error(`AI group "${group.name}" has no members after removing WARP nodes`);
  }
  return aiGroups;
}

// Validate and sanitize before a push writes configuration or backup rows.
export function normalizePushedAiContent(content) {
  const config = parse(content, { logLevel: 'silent', prettyErrors: false });
  const aiGroups = filterAiGroups(config);
  if (!aiGroups.length) return content;
  const names = new Set(aiGroups.map(group => group.name));
  const aiRules = [];
  const remaining = [];
  for (const rule of config.rules ?? []) {
    const parts = rule.split(',').map(value => value.trim());
    const target = parts.at(-1) === 'no-resolve' ? parts.at(-2) : parts.at(-1);
    (names.has(target) ? aiRules : remaining).push(rule);
  }
  const boundary = remaining.findIndex(rule => /^(?:GEOIP,|GEOSITE,cn,)/i.test(rule.trim()));
  remaining.splice(boundary < 0 ? 0 : boundary, 0, ...aiRules);
  config.rules = remaining;
  return stringify(config, { lineWidth: 0 });
}

export function applyRoutingPolicy(input) {
  const config = structuredClone(input);
  const target = defaultTarget(config);
  if (!target) throw new Error('No usable overseas proxy group');
  const aiGroups = filterAiGroups(config);
  if (!aiGroups.length) throw new Error('Subscription requires an AI proxy group; no fallback members are added');
  const aiTarget = aiGroups.find(group => group.name === policy.aiGroup)?.name ?? aiGroups[0].name;
  const { hasProxy } = graph(config);
  for (const group of config['proxy-groups']) {
    if (!aiGroups.includes(group) && hasProxy(group.name) && Array.isArray(group.proxies)) {
      group.proxies = group.proxies.filter(name => hasProxy(name));
    }
  }
  const preserved = [];
  for (const rule of config.rules ?? []) {
    const parts = rule.split(',').map(value => value.trim());
    if (!['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-WILDCARD', 'GEOSITE'].includes(parts[0]) || parts.length !== 3) continue;
    if (hasProxy(parts[2]) || aiName(parts[2])) preserved.push(`${parts[0]},${parts[1]},${aiName(parts[2]) ? parts[2] : target}`);
  }
  config.rules = [...new Set([
    ...policy.privateRules,
    ...policy.domesticAiDomains.map(domain => `DOMAIN-SUFFIX,${domain},DIRECT`),
    ...policy.aiRules.map(rule => `${rule},${aiTarget}`),
    ...policy.overseasRules.map(rule => `${rule},${target}`),
    ...preserved.filter(rule => aiGroups.some(group => rule.endsWith(`,${group.name}`))),
    'GEOSITE,cn,DIRECT', ...preserved.filter(rule => !aiGroups.some(group => rule.endsWith(`,${group.name}`))),
    `GEOSITE,geolocation-!cn,${target}`, 'GEOIP,CN,DIRECT', `MATCH,${target}`,
  ])];
  const dns = config.dns ?? {};
  const nameserverPolicy = { ...(dns['nameserver-policy'] ?? {}) };
  for (const rule of config.rules) {
    const [type, payload, ruleTarget] = rule.split(',');
    if (!aiGroups.some(group => group.name === ruleTarget)) continue;
    if (type === 'DOMAIN') nameserverPolicy[payload] = `https://1.1.1.1/dns-query#${ruleTarget}`;
    if (type === 'DOMAIN-SUFFIX') nameserverPolicy[`+.${payload}`] = `https://1.1.1.1/dns-query#${ruleTarget}`;
    if (type === 'GEOSITE') nameserverPolicy[`geosite:${payload}`] = `https://1.1.1.1/dns-query#${ruleTarget}`;
  }
  for (const domain of policy.domesticAiDomains) nameserverPolicy[`+.${domain}`] = policy.directDns;
  nameserverPolicy['geosite:private'] = ['system://'];
  nameserverPolicy['geosite:cn'] = policy.directDns;
  config.dns = {
    ...dns, enable: true,
    'nameserver-policy': nameserverPolicy,
    nameserver: [`https://1.1.1.1/dns-query#${target}`, `https://dns.google/dns-query#${target}`],
    'proxy-server-nameserver': ['223.5.5.5', '119.29.29.29'],
    'direct-nameserver': ['system://', ...policy.directDns],
    'direct-nameserver-follow-policy': true, 'respect-rules': true,
  };
  if ((dns['fake-ip-filter-mode'] ?? 'blacklist') === 'blacklist') {
    config.dns['fake-ip-filter'] = [...new Set([...(dns['fake-ip-filter'] ?? []), 'geosite:private', 'geosite:cn', ...policy.connectivityFakeIpFilters])];
  }
  return config;
}

// Legacy clients use this marker to retain the administrator's complete rules.
export function normalizeRoutingContent(content) {
  let config;
  try {
    config = parse(content, { logLevel: 'silent', prettyErrors: false });
  } catch {
    throw new Error('Invalid routing configuration YAML');
  }
  if (!Array.isArray(config?.proxies) || !config.proxies.length || !Array.isArray(config['proxy-groups']) || !config['proxy-groups'].length) return content;
  const normalized = applyRoutingPolicy(config);
  normalized['harmony-runtime'] ??= {};
  return stringify(normalized, { lineWidth: 0 });
}
