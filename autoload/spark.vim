" autoload/spark.vim -- spark in vim (the third smart tool). One key opens
" the `spark> ` prompt; Enter alone completes at the cursor, words rewrite
" the selection (or the whole file when nothing is selected), `? words`
" asks in a pane on the right, `?` alone reviews, `?? words` goes on in the
" newest pane's thread. Every run is one call to `spark edit` (contract 10)
" with the text on stdin: the plugin never speaks HTTP, never sees a token,
" never sends the file's path -- spark owns all of that. Solicited only:
" nothing runs until you ask.
"
" In a spark pane, single keys act: q and Escape close it, Enter jumps to
" the quote on the line, a applies the code block under the cursor, d
" declines the note under the cursor (spark edit --decline).
"
" The plugin binds NO key itself: the two lines are the user's (README):
"     nnoremap <M-s> :call spark#prompt(0)<CR>
"     xnoremap <M-s> :<C-u>call spark#prompt(1)<CR>
" Switch it off with `let g:spark_disable = 1`.

let s:VERSION = '1.0.0'

let s:pending = 0          " one run at a time
let s:current = {}         " the state of the run in flight

" The panes: pane bufnr -> {origin_buf, origin_win, file, sel, thread};
" s:newest is the one `??` goes on in.
let s:panes = {}
let s:newest = -1

" ------------------------------------------------------------- helpers --
function! s:trim(s) abort
    return substitute(substitute(a:s, '^\s\+', '', ''), '\s\+$', '', '')
endfunction

function! s:basename(p) abort
    return substitute(a:p, '^.*/', '', '')
endfunction

" The binary: SPARK_BIN (tests), g:spark_bin, ~/.local/bin/spark (a GUI
" session may never have sourced the rc files that put it on PATH), then
" whatever PATH answers to.
function! s:bin() abort
    if !empty($SPARK_BIN)
        return $SPARK_BIN
    endif
    if exists('g:spark_bin') && !empty(g:spark_bin)
        return g:spark_bin
    endif
    if !empty($HOME) && filereadable($HOME . '/.local/bin/spark')
        return $HOME . '/.local/bin/spark'
    endif
    return 'spark'
endfunction

function! s:notice(msg) abort
    echo a:msg
    redraw
endfunction

function! s:moan(msg) abort
    echohl ErrorMsg
    echomsg a:msg
    echohl None
endfunction

" One UTF-8 character's bytes at byte column `col` of `line`.
function! s:charlen(line, col) abort
    return strlen(matchstr(strpart(a:line, a:col), '.'))
endfunction

" The buffer as the bytes spark gets on stdin; the same construction feeds
" the --at/--sel offset math, so an offset always indexes these bytes.
function! s:buffer_text(buf) abort
    let text = join(getbufline(a:buf, 1, '$'), "\n")
    if getbufvar(a:buf, '&eol')
        let text .= "\n"
    endif
    return text
endfunction

" Byte offset of {row (0-based), byte col} in the current buffer.
function! s:offset_at(row, col) abort
    return line2byte(a:row + 1) - 1 + a:col
endfunction

" Where the write position lands after `chunk` goes in at [row, col].
function! s:advance(loc, chunk) abort
    let pieces = split(a:chunk, "\n", 1)
    if len(pieces) > 1
        return [a:loc[0] + len(pieces) - 1, strlen(pieces[-1])]
    endif
    return [a:loc[0], a:loc[1] + strlen(a:chunk)]
endfunction

function! s:insert_at(buf, loc, chunk) abort
    let line = get(getbufline(a:buf, a:loc[0] + 1), 0, '')
    let combined = strpart(line, 0, a:loc[1]) . a:chunk . strpart(line, a:loc[1])
    let parts = split(combined, "\n", 1)
    call setbufline(a:buf, a:loc[0] + 1, parts[0])
    if len(parts) > 1
        call appendbufline(a:buf, a:loc[0] + 1, parts[1:])
    endif
endfunction

" ---------------------------------------------------------- selections --
" sel: {kind: 'char'|'line', s_row, s_col, e_row, e_col, text} -- rows
" 0-based, byte columns, end exclusive; 'line' spans whole rows and its
" text carries the trailing newline. Read from the '< '> marks the
" x-mapping leaves behind.
function! s:selection(buf) abort
    let mode = visualmode()
    let [sr, sc] = [line("'<"), col("'<")]
    let [er, ec] = [line("'>"), col("'>")]
    if sr == 0 || er == 0
        return {}
    endif
    if mode ==# 'V'
        let lines = getbufline(a:buf, sr, er)
        return {'kind': 'line', 's_row': sr - 1, 'e_row': er - 1,
              \ 'text': join(lines, "\n") . "\n"}
    endif
    let last = get(getbufline(a:buf, er), 0, '')
    let e_col = min([ec - 1 + s:charlen(last, ec - 1), strlen(last)])
    let lines = getbufline(a:buf, sr, er)
    if empty(lines)
        return {}
    endif
    let lines[-1] = strpart(lines[-1], 0, e_col)
    let lines[0] = strpart(lines[0], sc - 1)
    if sr == er
        let lines[0] = strpart(get(getbufline(a:buf, sr), 0, ''), sc - 1, e_col - (sc - 1))
    endif
    return {'kind': 'char', 's_row': sr - 1, 's_col': sc - 1, 'e_row': er - 1,
          \ 'e_col': e_col, 'text': join(lines, "\n")}
endfunction

" What the buffer holds now where sel was, or an empty answer when gone.
function! s:text_of(buf, sel) abort
    if a:sel.kind ==# 'line'
        if a:sel.e_row + 1 > len(getbufline(a:buf, 1, '$'))
            return v:null
        endif
        let lines = getbufline(a:buf, a:sel.s_row + 1, a:sel.e_row + 1)
        if empty(lines)
            return v:null
        endif
        return join(lines, "\n") . "\n"
    endif
    let lines = getbufline(a:buf, a:sel.s_row + 1, a:sel.e_row + 1)
    if len(lines) != a:sel.e_row - a:sel.s_row + 1
        return v:null
    endif
    if a:sel.e_col > strlen(lines[-1])
        return v:null
    endif
    let lines[-1] = strpart(lines[-1], 0, a:sel.e_col)
    let lines[0] = strpart(lines[0], a:sel.s_col)
    if a:sel.s_row == a:sel.e_row
        let whole = get(getbufline(a:buf, a:sel.s_row + 1), 0, '')
        let lines[0] = strpart(whole, a:sel.s_col, a:sel.e_col - a:sel.s_col)
    endif
    return join(lines, "\n")
endfunction

" The splice: replace sel with acc in buf (whole lines in, whole lines out).
function! s:replace_range(buf, sel, acc) abort
    " deleting every line leaves vim's one empty line behind: remember
    " whether the range was the whole buffer, and drop the stray after
    let had = len(getbufline(a:buf, 1, '$'))
    let whole = a:sel.s_row == 0 && a:sel.e_row + 1 >= had
    if a:sel.kind ==# 'line'
        let body = substitute(a:acc, '\n$', '', '')
        let block = split(body, "\n", 1)
        call deletebufline(a:buf, a:sel.s_row + 1, a:sel.e_row + 1)
        call appendbufline(a:buf, a:sel.s_row, block)
        if whole
            call deletebufline(a:buf, len(block) + 1)
        endif
        return [[a:sel.s_row, 0], [a:sel.s_row + len(block) - 1, strlen(block[-1])]]
    endif
    let first = get(getbufline(a:buf, a:sel.s_row + 1), 0, '')
    let last = get(getbufline(a:buf, a:sel.e_row + 1), 0, '')
    let combined = strpart(first, 0, a:sel.s_col) . a:acc . strpart(last, a:sel.e_col)
    let parts = split(combined, "\n", 1)
    call deletebufline(a:buf, a:sel.s_row + 1, a:sel.e_row + 1)
    call appendbufline(a:buf, a:sel.s_row, parts)
    if whole
        call deletebufline(a:buf, len(parts) + 1)
    endif
    let to = s:advance([a:sel.s_row, a:sel.s_col], a:acc)
    return [[a:sel.s_row, a:sel.s_col], to]
endfunction

" The selection left on the splice (a proposal, never silent): focus the
" window, then select; end col points at the last character, inclusive.
function! s:select_range(win, from, to) abort
    if win_gotoid(a:win) != 1
        return
    endif
    call cursor(a:from[0] + 1, a:from[1] + 1)
    normal! v
    call cursor(a:to[0] + 1, max([a:to[1], 1]))
endfunction

function! s:argv(buf, extra) abort
    let args = ['edit', '--type', getbufvar(a:buf, '&filetype')]
    let path = bufname(a:buf)
    if !empty(path)
        call add(args, '--name')
        call add(args, s:basename(path))
    endif
    let about = getbufvar(a:buf, 'spark_about', get(g:, 'spark_about', ''))
    if !empty(about)
        call add(args, '--about')
        call add(args, about)
    endif
    return args + a:extra
endfunction

" ---------------------------------------------------------------- pane --
function! s:forget(pbuf) abort
    if has_key(s:panes, a:pbuf)
        call remove(s:panes, a:pbuf)
    endif
    if s:newest == a:pbuf
        let s:newest = -1
    endif
endfunction

let s:ASK_KEYS = 'spark: q closes; Enter jumps to a quote, a applies code, d declines a note, ?? goes on'

" A new pane on the right; `sel` is the selection the pane's question was
" about ({} for the whole file).
function! s:open_pane(bp, sel) abort
    botright vertical new
    setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
    setlocal wrap linebreak nonumber filetype=markdown
    let pbuf = bufnr('%')
    nnoremap <buffer> <nowait> <silent> q :call spark#pane_close()<CR>
    nnoremap <buffer> <nowait> <silent> <Esc> :call spark#pane_close()<CR>
    nnoremap <buffer> <nowait> <silent> <CR> :call spark#pane_jump()<CR>
    nnoremap <buffer> <nowait> <silent> a :call spark#pane_apply()<CR>
    nnoremap <buffer> <nowait> <silent> d :call spark#pane_decline()<CR>
    augroup sparkpane
        autocmd! BufWipeout <buffer> call s:forget(str2nr(expand('<abuf>')))
    augroup END
    let path = bufname(a:bp.buf)
    let entry = {'origin_buf': a:bp.buf, 'origin_win': a:bp.win,
               \ 'file': empty(path) ? '' : s:basename(path), 'sel': a:sel,
               \ 'thread': printf('edit-%d-%04d', localtime(), rand() % 10000)}
    let s:panes[pbuf] = entry
    let s:newest = pbuf
    return [pbuf, entry]
endfunction

" An answer that cannot be spliced is still an answer: a pane holds it.
function! s:show_pane(bp, text) abort
    let [pbuf, entry] = s:open_pane(a:bp, {})
    call s:insert_at(pbuf, [0, 0], a:text)
endfunction

function! s:origin_of(entry) abort
    if !bufexists(a:entry.origin_buf)
        return {}
    endif
    let win = a:entry.origin_win
    if win_id2win(win) == 0 || winbufnr(win_id2win(win)) != a:entry.origin_buf
        let wins = win_findbuf(a:entry.origin_buf)
        if empty(wins)
            return {}
        endif
        let win = wins[0]
        let a:entry.origin_win = win
    endif
    return {'buf': a:entry.origin_buf, 'win': win}
endfunction

" ---------------------------------------------------------------- jobs --
" state: {kind, bp, buf, loc, start, sel, acc, err, got, ...}
function! s:on_out(state, ch, chunk) abort
    try
        if empty(a:chunk)
            return
        endif
        let a:state.got = 1
        if index(['rewrite', 'decline', 'notice'], a:state.kind) >= 0
            let a:state.acc .= a:chunk
            return
        endif
        call s:insert_at(a:state.buf, a:state.loc, a:chunk)
        let a:state.loc = s:advance(a:state.loc, a:chunk)
    catch
        let s:pending = 0
        call s:moan('spark: ' . v:exception)
    endtry
endfunction

function! s:on_err(state, ch, chunk) abort
    let a:state.err .= a:chunk
endfunction

" close_cb, not exit_cb: vim documents that buffered channel data reaches
" out_cb/err_cb before close_cb, while exit_cb may beat the last chunk.
function! s:on_close(state, ch) abort
    try
        call s:finish(a:state)
    catch
        let s:pending = 0
        call s:moan('spark: ' . v:exception)
    endtry
endfunction

function! s:finish(state) abort
    let s:pending = 0
    let s:current = {}
    let state = a:state
    if state.kind ==# 'notice'
        let why = s:trim(!empty(state.err) ? state.err : state.acc)
        call s:notice('spark: ' . (empty(why) ? 'done' : why))
        return
    endif
    if state.kind ==# 'decline'
        " silence and exit 0 is success; a refusal comes on stdout, a die
        " on stderr
        let why = s:trim(!empty(state.err) ? state.err : state.acc)
        if !empty(why)
            call s:moan(why)
            return
        endif
        call deletebufline(state.buf, state.from + 1, state.to)
        call s:notice('spark: declined -- not raised again for ' . state.file)
        return
    endif
    if !state.got
        let why = s:trim(state.err)
        call s:moan(empty(why) ? 'spark: nothing came back' : why)
        return
    endif
    if state.kind ==# 'rewrite'
        if state.acc ==# state.sel.text
            call s:notice('spark: unchanged')
            return
        endif
        " the text it rewrote must still be there: an edit meanwhile moved
        " or shrank it, and a splice over a stale range corrupts the file
        if s:text_of(state.buf, state.sel) !=# state.sel.text
            call s:show_pane(state.bp, state.acc)
            call s:notice('spark: the text changed while it thought -- the answer is in the pane, q closes')
            return
        endif
        if get(state, 'whole', 0)
            let body = substitute(state.acc, '\n$', '', '')
            let block = split(body, "\n", 1)
            call deletebufline(state.buf, 1, '$')
            call appendbufline(state.buf, 0, block)
            call deletebufline(state.buf, len(block) + 1)
            if win_gotoid(state.bp.win) == 1
                call cursor(1, 1)
            endif
            call s:notice('spark: the file is rewritten -- u undoes')
        else
            let [from, to] = s:replace_range(state.buf, state.sel, state.acc)
            call s:select_range(state.bp.win, from, to)
            call s:notice('spark: rewritten -- u undoes')
        endif
    elseif state.kind ==# 'ask'
        if has_key(state, 'anchor')
            let wins = win_findbuf(state.buf)
            if !empty(wins) && win_gotoid(wins[0]) == 1
                call cursor(state.anchor[0] + 1, state.anchor[1] + 1)
            endif
        endif
        call s:notice(s:ASK_KEYS)
    else
        call s:select_range(state.bp.win, state.start, state.loc)
        call s:notice('spark: done -- u undoes')
    endif
endfunction

function! s:spawn(bp, args, stdin, state) abort
    let a:state.err = ''
    let a:state.got = 0
    if !has_key(a:state, 'acc')
        let a:state.acc = ''
    endif
    let s:pending = 1
    let s:current = a:state
    let job = job_start([s:bin()] + a:args, {
          \ 'out_mode': 'raw', 'err_mode': 'raw', 'in_io': 'pipe',
          \ 'out_cb': function('s:on_out', [a:state]),
          \ 'err_cb': function('s:on_err', [a:state]),
          \ 'close_cb': function('s:on_close', [a:state])})
    if job_status(job) !=# 'run'
        let s:pending = 0
        let s:current = {}
        call s:moan('spark: could not start ' . s:bin())
        return
    endif
    let a:state.job = job
    let ch = job_getchannel(job)
    call ch_sendraw(ch, a:stdin)
    call ch_close_in(ch)
    call s:notice('spark: thinking')
endfunction

" --------------------------------------------------------------- kinds --
function! s:complete(bp) abort
    let row = line('.') - 1
    let col = col('.') - 1
    " normal mode puts the cursor ON a character; the continuation goes
    " after it (end your text with a space and it begins exactly there)
    let line = getline('.')
    if strlen(line) > 0
        let col = min([col + s:charlen(line, col), strlen(line)])
    endif
    let at = s:offset_at(row, col)
    let state = {'kind': 'complete', 'bp': a:bp, 'buf': a:bp.buf,
               \ 'loc': [row, col], 'start': [row, col]}
    call s:spawn(a:bp, s:argv(a:bp.buf, ['--at', string(at)]), s:buffer_text(a:bp.buf), state)
endfunction

" The selection is what gets rewritten; nothing selected means the whole
" file, replaced in place. A selection travels with --part: a fragment
" must come back as exactly that fragment.
function! s:rewrite(bp, words, sel) abort
    let sel = a:sel
    if !empty(sel)
        let text = sel.text
        let extra = ['--part'] + a:words
        let whole = 0
    else
        let text = s:buffer_text(a:bp.buf)
        let sel = {'kind': 'line', 's_row': 0,
                 \ 'e_row': len(getbufline(a:bp.buf, 1, '$')) - 1, 'text': text}
        let extra = a:words
        let whole = 1
    endif
    let state = {'kind': 'rewrite', 'bp': a:bp, 'buf': a:bp.buf, 'acc': '',
               \ 'sel': sel, 'whole': whole}
    call s:spawn(a:bp, s:argv(a:bp.buf, extra), text, state)
endfunction

" A question: the WHOLE buffer goes on stdin; a selection travels as
" --sel A B (byte offsets). `follow` (?? words) goes on in the newest
" pane's thread: the same --thread id, the answer under the question.
function! s:ask(bp, words, follow, sel) abort
    let text = s:buffer_text(a:bp.buf)
    if empty(s:trim(text))
        call s:notice('spark: nothing to ask about')
        return
    endif
    let extra = []
    if !empty(a:sel)
        if a:sel.kind ==# 'line'
            let a = s:offset_at(a:sel.s_row, 0)
            let b = line2byte(a:sel.e_row + 2) - 1
            if b < 0
                let b = strlen(text)
            endif
        else
            let a = s:offset_at(a:sel.s_row, a:sel.s_col)
            let b = s:offset_at(a:sel.e_row, a:sel.e_col)
        endif
        let extra = ['--sel', string(a), string(b)]
    endif
    let extra += a:words
    if a:follow && s:newest >= 0 && has_key(s:panes, s:newest)
        let pbuf = s:newest
        let entry = s:panes[pbuf]
        let lines = getbufline(pbuf, 1, '$')
        let at = [len(lines) - 1, strlen(lines[-1])]
        let q = "\n\n> " . (len(a:words) > 1 ? join(a:words[1:], ' ') : '?') . "\n\n"
        call s:insert_at(pbuf, at, q)
        if !empty(a:sel)
            let entry.sel = a:sel
        endif
        let loc = s:advance(at, q)
        let state = {'kind': 'ask', 'bp': a:bp, 'buf': pbuf, 'loc': loc,
                   \ 'anchor': copy(loc)}
    else
        let [pbuf, entry] = s:open_pane(a:bp, a:sel)
        let state = {'kind': 'ask', 'bp': a:bp, 'buf': pbuf, 'loc': [0, 0]}
    endif
    let extra += ['--thread', entry.thread]
    call s:spawn(a:bp, s:argv(a:bp.buf, extra), text, state)
endfunction

" The ledger: what was declined for this file, in a pane; `clear` drops it.
function! s:ledger(bp, clear) abort
    if empty(bufname(a:bp.buf))
        call s:notice('spark: an unnamed buffer keeps no ledger -- save it first')
        return
    endif
    if a:clear
        call s:spawn(a:bp, s:argv(a:bp.buf, ['--ledger', 'clear']), '',
                   \ {'kind': 'notice', 'bp': a:bp, 'acc': '', 'err': ''})
        return
    endif
    let [pbuf, entry] = s:open_pane(a:bp, {})
    call s:spawn(a:bp, s:argv(a:bp.buf, ['--ledger']), '',
               \ {'kind': 'ask', 'bp': a:bp, 'buf': pbuf, 'loc': [0, 0]})
endfunction

" ------------------------------------------------------ the pane's keys --
" The first quoted span on a line: "..." or the curly pair or `...`.
function! s:first_quote(line) abort
    let best = -1
    let span = ''
    for pat in ['"\([^"]\+\)"', "“\\(\[^”]\\+\\)”", '`\([^`]\+\)`']
        let m = matchlist(a:line, pat)
        let at = match(a:line, pat)
        if at >= 0 && (best < 0 || at < best)
            let best = at
            let span = m[1]
        endif
    endfor
    return span
endfunction

" A vim pattern that matches `s` literally, any run of whitespace in it
" matching any run (the quote may cross a line break in the file).
function! s:loose_pattern(s) abort
    let esc = escape(a:s, '\')
    return '\V' . substitute(esc, '\s\+', '\\_s\\+', 'g')
endfunction

function! spark#pane_close() abort
    let pbuf = bufnr('%')
    if s:pending && get(s:current, 'buf', -1) == pbuf
        call s:notice('spark: still writing here -- a moment')
        return
    endif
    " bufhidden=wipe: closing the window wipes the buffer and its entry
    close!
endfunction

" Enter: the origin's cursor goes to the quote on this line, selected.
function! spark#pane_jump() abort
    let pbuf = bufnr('%')
    if !has_key(s:panes, pbuf)
        return
    endif
    let entry = s:panes[pbuf]
    let span = s:first_quote(getline('.'))
    if empty(span)
        call s:notice('spark: no quote on this line')
        return
    endif
    let origin = s:origin_of(entry)
    if empty(origin)
        call s:notice("spark: the file's window is closed")
        return
    endif
    let pat = s:loose_pattern(span)
    let pwin = win_getid()
    if win_gotoid(origin.win) != 1
        call s:notice("spark: the file's window is closed")
        return
    endif
    call cursor(1, 1)
    let s = searchpos(pat, 'cW')
    let e = s[0] != 0 ? searchpos(pat, 'ceW') : [0, 0]
    if s[0] == 0 || e[0] == 0
        call win_gotoid(pwin)
        call s:notice('spark: not in the text as written')
        return
    endif
    call cursor(s[0], s[1])
    normal! v
    call cursor(e[0], e[1])
endfunction

" The code block under the cursor: the lines indented four spaces around
" it (the brief's shape), dedented; else the fenced block the cursor is
" in. An empty answer when there is none.
function! s:code_block(lines, y) abort
    let n = len(a:lines)
    let Indented = {i -> a:lines[i] =~# '^    '}
    let Blank = {i -> empty(s:trim(a:lines[i]))}
    if Indented(a:y)
        let top = a:y
        let bot = a:y
        while top > 0 && (Indented(top - 1) || (Blank(top - 1) && top > 1 && Indented(top - 2)))
            let top -= 1
        endwhile
        while bot < n - 1 && (Indented(bot + 1) || (Blank(bot + 1) && bot + 2 < n && Indented(bot + 2)))
            let bot += 1
        endwhile
        let out = []
        for i in range(top, bot)
            call add(out, substitute(a:lines[i], '^    ', '', ''))
        endfor
        return join(out, "\n") . "\n"
    endif
    let Fence = {i -> a:lines[i] =~# '^\s*```'}
    let top = a:y
    while top >= 0 && !Fence(top)
        let top -= 1
    endwhile
    if top < 0
        return ''
    endif
    let bot = a:y + 1
    while bot < n && !Fence(bot)
        let bot += 1
    endwhile
    if bot >= n || bot <= top + 1
        return ''
    endif
    return join(a:lines[top + 1 : bot - 1], "\n") . "\n"
endfunction

" a: the code block under the cursor replaces the selection the question
" was about when it is still there, else lands at the origin's cursor.
function! spark#pane_apply() abort
    let pbuf = bufnr('%')
    if !has_key(s:panes, pbuf)
        return
    endif
    let entry = s:panes[pbuf]
    let text = s:code_block(getbufline(pbuf, 1, '$'), line('.') - 1)
    if empty(text)
        call s:notice('spark: no code here -- a block is indented four spaces, or fenced')
        return
    endif
    let origin = s:origin_of(entry)
    if empty(origin)
        call s:notice("spark: the file's window is closed")
        return
    endif
    if !empty(get(entry, 'sel', {})) && s:text_of(origin.buf, entry.sel) ==# entry.sel.text
        let sel = entry.sel
    else
        let pos = win_gotoid(origin.win) == 1 ? [line('.') - 1, col('.') - 1] : [0, 0]
        let sel = {'kind': 'char', 's_row': pos[0], 's_col': pos[1],
                 \ 'e_row': pos[0], 'e_col': pos[1], 'text': ''}
    endif
    let [from, to] = s:replace_range(origin.buf, sel, text)
    let entry.sel = {'kind': 'char', 's_row': from[0], 's_col': from[1],
                   \ 'e_row': to[0], 'e_col': to[1], 'text': text}
    call s:select_range(origin.win, from, to)
    call s:notice('spark: applied -- u undoes')
endfunction

" d: the note under the cursor (the numbered paragraph, or the paragraph)
" goes to the ledger; it leaves the pane when spark has kept it.
function! spark#pane_decline() abort
    let pbuf = bufnr('%')
    if !has_key(s:panes, pbuf)
        return
    endif
    let entry = s:panes[pbuf]
    if empty(entry.file)
        call s:notice('spark: an unnamed buffer keeps no ledger -- save it first')
        return
    endif
    if s:pending
        call s:notice('spark: still working -- one at a time')
        return
    endif
    let lines = getbufline(pbuf, 1, '$')
    let n = len(lines)
    let y = line('.') - 1
    let Numbered = {i -> lines[i] =~# '^\d\+[.)]\s'}
    let Blank = {i -> empty(s:trim(lines[i]))}
    if Blank(y)
        call s:notice('spark: no note here')
        return
    endif
    let top = y
    while top > 0 && !Numbered(top) && !Blank(top - 1)
        let top -= 1
    endwhile
    let bot = y
    while bot + 1 < n && !Blank(bot + 1) && !Numbered(bot + 1)
        let bot += 1
    endwhile
    let note = join(lines[top : bot], "\n") . "\n"
    let state = {'kind': 'decline', 'bp': {'buf': pbuf}, 'buf': pbuf,
               \ 'from': top, 'to': bot + 1, 'file': entry.file, 'acc': ''}
    call s:spawn(state.bp, ['edit', '--decline', '--name', entry.file], note, state)
endfunction

" ------------------------------------------------------------- the key --
function! s:run(bp, line, sel) abort
    let line = s:trim(a:line)
    let bp = a:bp
    let sel = a:sel
    if s:pending
        call s:notice('spark: still working -- one at a time')
        return
    endif
    " from inside a spark pane, the file it belongs to is meant
    if has_key(s:panes, bp.buf)
        let origin = s:origin_of(s:panes[bp.buf])
        if empty(origin)
            call s:notice("spark: the file's window is closed")
            return
        endif
        let bp = origin
        let sel = {}
    endif
    if !getbufvar(bp.buf, '&modifiable') || getbufvar(bp.buf, '&readonly')
        call s:moan('spark: this buffer is read-only')
        return
    endif
    if empty(line)
        call s:complete(bp)
    elseif line[0:1] ==# '??'
        call s:ask(bp, ['?'] + split(line[2:]), 1, sel)
    elseif line[0] ==# '?'
        call s:ask(bp, ['?'] + split(line[1:]), 0, sel)
    elseif line ==# 'ledger' || line ==# 'ledger clear'
        call s:ledger(bp, line ==# 'ledger clear')
    elseif line ==# 'lua'
        " the one word that is not an instruction: the shell has it
        call s:notice('spark lua -- this one runs in the dark; ask your shell')
    else
        call s:rewrite(bp, split(line), sel)
    endif
endfunction

function! spark#prompt(visual) abort
    if get(g:, 'spark_disable', 0)
        return
    endif
    if s:pending
        call s:notice('spark: still working -- one at a time')
        return
    endif
    let bp = {'buf': bufnr('%'), 'win': win_getid()}
    let sel = a:visual ? s:selection(bp.buf) : {}
    try
        let resp = input('spark> ')
    catch /Vim:Interrupt/
        return
    endtry
    redraw
    call s:run(bp, resp, sel)
endfunction

function! spark#command(range, line1, line2, args) abort
    if get(g:, 'spark_disable', 0)
        return
    endif
    let bp = {'buf': bufnr('%'), 'win': win_getid()}
    let sel = {}
    if a:range > 0
        let lines = getbufline(bp.buf, a:line1, a:line2)
        let sel = {'kind': 'line', 's_row': a:line1 - 1, 'e_row': a:line2 - 1,
                 \ 'text': join(lines, "\n") . "\n"}
    endif
    call s:run(bp, a:args, sel)
endfunction

" The load check the pre-commit hook calls; also the user's doctor.
function! spark#health() abort
    let fine = has('job') && has('channel') && exists('*appendbufline')
    if !fine
        echomsg 'spark: this vim lacks +job/+channel -- 8.2 or newer, a huge build'
    endif
    return fine
endfunction
