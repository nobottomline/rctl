import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { stripTypeScriptTypes } from 'node:module'
const source = stripTypeScriptTypes(await readFile(new URL('../src/lib/guestNavigation.ts', import.meta.url), 'utf8'))
const { guestTools, guestTime } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

test('guest navigation shows only the tools supported by the exact granted rights', () => {
  assert.deepEqual(guestTools(['screen.view', 'input.keyboard', 'input.button.home']), [])
  assert.deepEqual(guestTools(['capture.download']), [])
  assert.deepEqual(guestTools(['files.list', 'files.download']).map(t => t.id), ['files'])
  assert.deepEqual(guestTools(['camera.record', 'capture.download']).map(t => t.id), ['camera'])
  assert.deepEqual(guestTools(['talk.virtual_microphone', 'terminal.root']).map(t => t.id), ['sound', 'terminal'])
  assert.deepEqual(guestTools(['clipboard.read', 'screen.snapshot']).map(t => t.id), ['console'])
})

test('guest countdown is bounded and displays hours for long grants', () => {
  assert.equal(guestTime(-1), '0:00'); assert.equal(guestTime(59.2), '1:00')
  assert.equal(guestTime(3600), '1:00:00'); assert.equal(guestTime(86400), '24:00:00')
})
