import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { name, version } = require('../package.json');

console.log(`[${name}@${version}] loaded`);

export { name, version };

export function greet(target = 'world') {
  return `Hello, ${target}! From ${name}@${version}`;
}
