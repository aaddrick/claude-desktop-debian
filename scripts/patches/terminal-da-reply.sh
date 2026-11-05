# shellcheck shell=bash
#===============================================================================
# Terminal panel: answer DA1 queries from the main process.
#
# Fish 4.x sends a Primary Device Attribute query (ESC[0c) at startup
# and around each command, then blocks for up to 10 seconds waiting for
# the answer. The terminal panel can start a shell before its xterm is
# on screen (the Run button, run_in_terminal), so the query is only
# buffered. When the buffer is finally shown, xterm answers, but the
# renderer deliberately drops terminal reports during replay. Fish never
# hears back, so the tab sits blank for 10 seconds, prints a warning,
# and loses any command pasted during the wait (#966).
#
# The main process sees the query the moment the shell emits it,
# whatever the renderer is doing, so it answers there. Every answer it
# sends is recorded on the pty, and the matching xterm answer is dropped
# in writeShellPty. A shell on screen therefore still gets exactly one
# reply, which matters for programs that exit right after reading it:
# a second reply would land in the shell's prompt as stray text.
#
# Interim fix pending upstream; this is not a net-new feature. Upstream
# can fix this in ion-dist.asar, which this patch never reads, so a
# no-op here cannot prove it fixed: retire on a repro that no longer
# reproduces (docs/upstream-reports/terminal-da1-hidden-shell.md).
#
# Sourced by: build.sh
# Sourced globals: (none — resolves its own file via _resolve_anchor_file,
#   defined in app-asar.sh)
# Modifies globals: (none)
#===============================================================================

patch_terminal_da_reply() {
	echo 'Patching terminal panel DA1 replies (hidden shell startup)...'

	local target_js
	target_js=$(_resolve_anchor_file 'shell pty data handler' \
		'\.onData\([\w$.]+\(\s*[`"'"'"']pty:shell-data[`"'"'"']') \
		|| return 1

	if TARGET_JS="$target_js" node << 'TERMINAL_DA_PATCH'
const fs = require('fs');
const targetJs = process.env.TARGET_JS;
let code = fs.readFileSync(targetJs, 'utf8');

const owed = '__cddDa1Owed';
const tail = '__cddDa1Tail';

// Keyed to the private property name, which upstream cannot emit. Both
// sites go in together, so one without the other is a corrupt bundle:
// the query site alone would double-answer every shell on screen.
const querySeen = code.includes('.' + tail);
const replySeen = code.includes('.' + owed + '>0');
if (querySeen && replySeen) {
    console.log('  Terminal DA1 reply already applied');
    process.exit(0);
}
if (querySeen !== replySeen) {
    console.log('  WARNING: only one of the two DA1 patch sites is ' +
        'present — re-extract a pristine asar and re-run');
    process.exit(1);
}

// Receiver and data parameter are captured, not hardcoded: they change
// every release (docs/learnings/patching-minified-js.md). The receiver
// admits a property chain so a chained pty cannot match on its tail.
// Intent: PTY.onData(WRAP("pty:shell-data",(DATA=>{
const dataRe = new RegExp(
    String.raw`([\w$]+(?:\.[\w$]+)*)\.onData\(\s*[\w$]+(?:\.[\w$]+)*\(\s*` +
    '[`"\']pty:shell-data[`"\']' +
    String.raw`\s*,\s*\(*\s*([\w$]+)\s*\)?\s*=>\s*\{`,
    'g');
const dataMatches = [...code.matchAll(dataRe)];
if (dataMatches.length !== 1) {
    console.log('  WARNING: expected exactly 1 pty:shell-data handler, ' +
        'found ' + dataMatches.length);
    process.exit(1);
}

// Exactly one definition per resolved file. The IPC dispatcher that
// forwards to this method lives in a different chunk.
// Intent: writeShellPty(KEY,INPUT,ORIGIN){
const writeRe = /\bwriteShellPty\(\s*([\w$]+)\s*,\s*([\w$]+)\s*,\s*[\w$]+\s*\)\s*\{/g;
const writeMatches = [...code.matchAll(writeRe)];
if (writeMatches.length !== 1) {
    console.log('  WARNING: expected exactly 1 writeShellPty definition, ' +
        'found ' + writeMatches.length);
    process.exit(1);
}

const dataMatch = dataMatches[0];
const before = code.slice(0, dataMatch.index).replace(/\s+$/, '');
if (/[\w$.]$/.test(before)) {
    console.log('  WARNING: pty:shell-data receiver matched ' +
        'mid-expression (prefix ends "' + before.slice(-16) + '") — ' +
        'widen the receiver capture');
    process.exit(1);
}

const pty = dataMatch[1];
const data = dataMatch[2];
const reply = String.raw`"\x1b[?1;2c"`;

// The tail keeps a query split across two reads. Only a partial query
// is kept, so a complete one can never be counted twice.
const answerQueries =
    '{let cddQ=(' + pty + '.' + tail + '??"")+' + data + ',' +
    String.raw`cddN=cddQ.match(/\x1b\[0?c/g)?.length??0;` +
    pty + '.' + tail + '=' +
    String.raw`/\x1b(?:\[0?)?$/.exec(cddQ)?.[0]??"";` +
    'for(let cddI=0;cddI<cddN;cddI++)' +
    pty + '.' + owed + '=(' + pty + '.' + owed + '??0)+1,' +
    pty + '.write(' + reply + ')}';

const writeMatch = writeMatches[0];
const key = writeMatch[1];
const input = writeMatch[2];

// `this` here is the manager whose shellPtyProcesses the handler above
// checks, and the method's own first read of it uses the same key.
const dropReply =
    'if(' + input + '===' + reply + '){' +
    'let cddP=this.shellPtyProcesses.get(' + key + ');' +
    'if(cddP?.' + owed + '>0){cddP.' + owed + '--;return}}';

if (!code.slice(writeMatch.index, writeMatch.index + 2000)
    .includes('this.shellPtyProcesses.get(' + key + ')')) {
    console.log('  WARNING: writeShellPty no longer reads ' +
        'this.shellPtyProcesses — re-derive the patch');
    process.exit(1);
}

// Splice the later site first so the earlier offset stays valid.
const sites = [
    [dataMatch.index + dataMatch[0].length, answerQueries],
    [writeMatch.index + writeMatch[0].length, dropReply],
].sort((a, b) => b[0] - a[0]);
for (const [at, text] of sites) {
    code = code.substring(0, at) + text + code.substring(at);
}

fs.writeFileSync(targetJs, code);
console.log('  Shell pty (' + pty + ') now answers DA1 from the main ' +
    'process');
TERMINAL_DA_PATCH
	then
		echo 'Terminal DA1 reply applied'
	else
		echo 'ERROR: terminal DA1 patch failed. Without it, fish 4.x tabs' \
			'started off screen stall for 10 seconds and lose pasted' \
			'commands. Update the anchors in' \
			'scripts/patches/terminal-da-reply.sh against the new bundle,' \
			'or, if upstream fixed the replay filter, retire the patch' \
			'(docs/upstream-reports/terminal-da1-hidden-shell.md). To' \
			'unblock a security-bearing release, dropping' \
			'patch_terminal_da_reply from active_patches is a legitimate' \
			'stopgap; file the follow-up issue.' >&2
		return 1
	fi
	echo '##############################################################'
}
