import { readdir, readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import Ajv2020 from 'ajv/dist/2020.js'

const root = dirname(fileURLToPath(import.meta.url))
const manifest = JSON.parse(await readFile(resolve(root, 'fixtures/manifest.json'), 'utf8'))
const ajv = new Ajv2020({ allErrors: true, strict: true })
const validators = new Map()

for (const name of await readdir(resolve(root, 'schemas'))) {
  if (!name.endsWith('.schema.json')) continue
  const schema = JSON.parse(await readFile(resolve(root, 'schemas', name), 'utf8'))
  validators.set(name, ajv.compile(schema))
}

let failed = false
const registered = new Set(['manifest.json'])
for (const entry of manifest.fixtures) {
  const validate = validators.get(entry.schema)
  if (!validate) throw new Error(`unknown fixture schema: ${entry.schema}`)
  const fixturePath = resolve(root, 'fixtures', entry.path)
  const value = JSON.parse(await readFile(fixturePath, 'utf8'))
  const valid = validate(value)
  registered.add(entry.path)
  if (valid !== entry.valid) {
    failed = true
    const errors = validate.errors ? ajv.errorsText(validate.errors, { separator: '\n    ' }) : 'none'
    process.stderr.write(`${entry.path}: expected valid=${entry.valid}, got ${valid}\n    ${errors}\n`)
  }
}

async function findJSONFiles(directory, prefix = '') {
  const files = []
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) files.push(...(await findJSONFiles(resolve(directory, entry.name), relative)))
    else if (entry.name.endsWith('.json')) files.push(relative)
  }
  return files
}

for (const path of await findJSONFiles(resolve(root, 'fixtures'))) {
  if (!registered.has(path)) {
    failed = true
    process.stderr.write(`${path}: fixture is not registered in fixtures/manifest.json\n`)
  }
}

if (failed) process.exitCode = 1
else process.stdout.write(`validated ${manifest.fixtures.length} protocol fixtures\n`)
