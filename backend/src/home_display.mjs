import { Validator } from '@cfworker/json-schema';
import schema from '../homepage/schema.json' with { type: 'json' };
import defaultHome from '../homepage/home.json' with { type: 'json' };

export const HOME_DISPLAY_KEY = 'ui:home';
export const HOME_DISPLAY_MAX_BYTES = 64 * 1024;
export const DEFAULT_HOME_DISPLAY = JSON.stringify(defaultHome);
const validator = new Validator(schema);

export function parseHomeDisplay(content) {
  if (new TextEncoder().encode(content).byteLength > HOME_DISPLAY_MAX_BYTES) {
    throw new Error('Home display configuration exceeds 64 KiB');
  }
  let document;
  try { document = JSON.parse(content); } catch { throw new Error('Invalid home display JSON'); }
  if (!validator.validate(document).valid) throw new Error('Invalid home display configuration');
  return document;
}
