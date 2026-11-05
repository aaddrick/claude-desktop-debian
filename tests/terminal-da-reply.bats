#!/usr/bin/env bats
#
# patch_terminal_da_reply: the main process answers DA1 queries for
# shells whose xterm is off screen or replaying, and drops the xterm
# answer it already covered.
#
# The behavior tests run the patched manager rather than grepping for
# the injected text, so dropping either site, the query tail or the
# "owed" guard goes red. The near-miss fixtures sit one edit away from
# the anchors (docs/learnings/test-methodology-and-coverage.md).

setup() {
	# shellcheck source=scripts/patches/terminal-da-reply.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/terminal-da-reply.sh"
	# shellcheck source=scripts/patches/app-asar.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"

	cd "$BATS_TEST_TMPDIR" || return 1
	build_dir='app.asar.contents/.vite/build'
	mkdir -p "$build_dir"
	target="$build_dir/index.chunk-test.js"

	# Real 4.16336.0 minified shapes, reduced to a loadable class.
	# `t` is both the module handle and the data parameter upstream.
	# shellcheck disable=SC2016  # the backticks are literal JS templates
	fixture='var t={lgt:(n,f)=>f};module.exports=class{constructor(){this.shellPtyProcesses=new Map;this.written=[]}attach(e,B){this.shellPtyProcesses.set(e,B),B.onData(t.lgt(`pty:shell-data`,(t=>{if(this.shellPtyProcesses.get(e)!==B)return;this.seen=t})))}writeShellPty(e,n,r){let a=this.shellPtyProcesses.get(e);if(!a)return;a.write(n),this.written.push(n)}};'
}

_write_fixture() {
	printf '%s\n' "$1" > "$target"
}

# Drives the patched manager with fake ptys and prints what each scenario
# wrote to the pty. Assertions compare the output, not the patched text.
_drive() {
	local scenario="$1"

	TARGET="$PWD/$target" SCENARIO="$scenario" node << 'DRIVE'
const M = require(process.env.TARGET);
const m = new M();
const pty = { sent: [], write(d) { this.sent.push(d); },
    onData(f) { this.emit = f; } };
m.attach('tab', pty);
const reply = '\x1b[?1;2c';
const show = () => console.log(JSON.stringify(pty.sent));
switch (process.env.SCENARIO) {
case 'query':
    pty.emit('\x1b[0c');
    break;
case 'bare':
    pty.emit('\x1b[c');
    break;
case 'two-in-one':
    pty.emit('a\x1b[0cb\x1b[0c');
    break;
case 'secondary':
    pty.emit('\x1b[>0c\x1b[6n');
    break;
case 'split':
    pty.emit('prompt\x1b[');
    pty.emit('0c');
    break;
case 'no-recount':
    pty.emit('\x1b[0c');
    pty.emit('text');
    break;
case 'on-screen':
    // xterm answers the same query the main process already answered.
    pty.emit('\x1b[0c');
    m.writeShellPty('tab', reply, 'person');
    break;
case 'unsolicited':
    // Nothing owed: an xterm report still reaches the shell.
    m.writeShellPty('tab', reply, 'person');
    break;
case 'typing':
    pty.emit('\x1b[0c');
    m.writeShellPty('tab', 'ls\r', 'person');
    break;
}
show();
DRIVE
}

@test "answers a DA1 query with xterm's reply" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive query
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "answers the parameterless query form" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive bare
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "answers every query in one read" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive two-in-one
	[[ $output == '["\u001b[?1;2c","\u001b[?1;2c"]' ]]
}

@test "leaves secondary attributes and cursor queries to xterm" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive secondary
	[[ $output == '[]' ]]
}

@test "answers a query split across two reads" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive split
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "does not recount an answered query on the next read" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive no-recount
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "a shell on screen gets exactly one reply" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive on-screen
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "an unsolicited report still reaches the shell" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive unsolicited
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "typed input is untouched" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	run _drive typing
	[[ $output == '["\u001b[?1;2c","ls\r"]' ]]
}

@test "a second run changes nothing" {
	_write_fixture "$fixture"
	patch_terminal_da_reply
	local first
	first=$(sha256sum "$target")
	patch_terminal_da_reply
	[[ $(sha256sum "$target") == "$first" ]]
}

@test "matches the double-quoted literal form" {
	_write_fixture "${fixture//\`pty:shell-data\`/\"pty:shell-data\"}"
	patch_terminal_da_reply
	run _drive query
	[[ $output == '["\u001b[?1;2c"]' ]]
}

@test "hard-fails when the data handler is gone" {
	_write_fixture "${fixture//pty:shell-data/pty:other-data}"
	run patch_terminal_da_reply
	[[ $status -ne 0 ]]
}

@test "hard-fails on a duplicate write definition" {
	_write_fixture "$fixture"'class X{writeShellPty(a,b,c){}}'
	run patch_terminal_da_reply
	[[ $status -ne 0 ]]
}

@test "hard-fails when writeShellPty stops reading the pty map" {
	_write_fixture "${fixture//let a=this.shellPtyProcesses.get(e);/let a=this.other.get(e);}"
	run patch_terminal_da_reply
	[[ $status -ne 0 ]]
}

@test "hard-fails when only one patch site is present" {
	_write_fixture "$fixture"'x.__cddDa1Tail;'
	run patch_terminal_da_reply
	[[ $status -ne 0 ]]
}

@test "hard-fails on a receiver the capture cannot express" {
	_write_fixture "${fixture//B.onData(/a[0].onData(}"
	run patch_terminal_da_reply
	[[ $status -ne 0 ]]
}
