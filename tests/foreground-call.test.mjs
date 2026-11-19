import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

// Run the actual tool-call body served to Codex. The runner has separate
// Windows integration tests. Here the host clock can advance without sleeping.
const skill = readFileSync(new URL('../plugins/codex-job-watch/skills/codex-job-watch/SKILL.md', import.meta.url), 'utf8');
const code = skill.match(/^```javascript\r?\n([\s\S]*?)^```/m)[1];
const outerWindow = JSON.parse(code.split('\n', 1)[0].replace(/^\/\/ @exec:\s*/, '')).yield_time_ms;
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const runForeground = new AsyncFunction('tools', 'text', code);

async function simulate({ duration, exitCode, receipt, loseHandle = false }) {
    let elapsed = 0;
    let starts = 0;
    let renewals = 0;
    let finished = false;
    const messages = [];
    const handle = 17;

    function wait(window, first) {
        assert.ok(window > 0);
        elapsed = Math.min(duration, elapsed + window);
        assert.ok(elapsed < outerWindow, 'outer call would hand control back to the model before completion');
        finished = elapsed === duration;
        const split = Math.floor(receipt.length / 2);
        const output = (first ? receipt.slice(0, split) : '') + (finished ? receipt.slice(split) : '');
        return { output, exit_code: finished ? exitCode : null, session_id: finished ? null : handle };
    }

    const tools = {
        async exec_command(args) {
            assert.equal(++starts, 1, 'job started more than once');
            return wait(args.yield_time_ms, true);
        },
        async write_stdin(args) {
            assert.equal(args.session_id, handle);
            assert.equal(args.chars, '');
            renewals++;
            if (loseHandle) return { output: '', exit_code: null };
            return wait(args.yield_time_ms, false);
        },
    };
    await runForeground(tools, result => {
        assert.ok(finished, 'model received an intermediate result');
        messages.push(result);
    });
    assert.equal(starts, 1);
    assert.deepEqual(messages, [{ exit_code: exitCode, output: receipt }]);
    return renewals;
}

test('an eight-hour virtual job stays in one model-visible call', async () => {
    const renewals = await simulate({ duration: 8 * 60 * 60 * 1000, exitCode: 0, receipt: '{"status":"succeeded"}' });
    assert.ok(renewals > 1);
});

test('an immediately finished job needs no shell renewal', async () => {
    assert.equal(await simulate({ duration: 0, exitCode: 0, receipt: '{"status":"succeeded"}' }), 0);
});

test('failure, cancellation and a bounded wait retain their actual result', async () => {
    for (const [exitCode, status] of [[1, 'failed'], [130, 'cancelled'], [124, 'wait_timeout']]) {
        await simulate({ duration: 125000, exitCode, receipt: JSON.stringify({ status }) });
    }
});

test('losing the shell handle raises an error without restarting the Job', async () => {
    await assert.rejects(simulate({ duration: 125000, exitCode: 0, receipt: '', loseHandle: true }), /handle/i);
});

test('Windows PowerShell receives the literal inputs and returns the runner exit code', { skip: process.platform !== 'win32' }, async () => {
    const cwd = mkdtempSync(join(tmpdir(), 'codex-job-bridge-'));
    const runner = join(cwd, "runner’s test.ps1");
    const name = "owner's build";
    const command = "Write-Output ‘literal’\nWrite-Output '$($value)'";
    const inputs = { runner, cwd, name, command };
    const fixture = 'param($Action, $Root, $Cwd, $Name, $Command)\n' +
        '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n' +
        '[ordered]@{action=$Action; root=$Root; cwd=$Cwd; name=$Name; command=$Command} | ConvertTo-Json -Compress\nexit 130';
    writeFileSync(runner, fixture);
    try {
        const body = code.replace(/^const (runner|cwd|name|command) = .*;$/gm,
            (_, key) => `const ${key} = ${JSON.stringify(inputs[key])};`);
        const host = {
            async exec_command({ cmd, workdir }) {
                const child = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
                    { cwd: workdir, windowsHide: true, encoding: 'utf8' });
                assert.ifError(child.error);
                assert.equal(child.status, 130, child.stderr);
                return { exit_code: child.status, output: child.stdout };
            },
        };
        const results = [];
        await new AsyncFunction('tools', 'text', body)(host, value => results.push(value));
        assert.equal(results.length, 1);
        assert.equal(results[0].exit_code, 130);
        assert.deepEqual(JSON.parse(results[0].output), { action: 'run', root: cwd, cwd, name, command });
    } finally {
        unlinkSync(runner);
        rmdirSync(cwd);
    }
});
