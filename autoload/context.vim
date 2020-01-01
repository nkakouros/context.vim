" TODO: highlight border line (and tag) differently
" TODO: on bufenter or something check all popups and close if their reference
" window is no longer valid
" TODO(dup?): close popup when relative window gets closed. how? always check
" when number of windows changed?
" also resize popups when window width changes, and update position
" TODO: also potentially resize them all
" TODO(dup?): don't hide cursor, hide (partially) context instead

" consts
let s:buffer_name = '<context.vim>'

" cached
let s:ellipsis  = repeat(g:context_ellipsis_char, 3)
let s:ellipsis5 = repeat(g:context_ellipsis_char, 5)
let s:nil_line  = {'number': 0, 'indent': 0, 'text': ''}

" state
" NOTE: there's more state in window local w: variables
let s:activated      = 0
let s:last_winid     = 0
let s:ignore_autocmd = 0
let s:log_indent     = 0
let s:popups         = {}


" call this on VimEnter to activate the plugin
function! context#activate() abort
    " for some reason there seems to be a race when we try to show context of
    " one buffer before another one gets opened in startup
    " to avoid that we wait for startup to be finished
    let s:activated = 1
    call context#update(0, 'VimEnter')
endfunction

function! context#enable() abort
    let g:context_enabled = 1
    call context#update(1, 0)
endfunction

function! context#disable() abort
    call s:popup_clear()
    let g:context_enabled = 0

    silent! wincmd P " jump to new preview window
    if &previewwindow
        let bufname = bufname('%')
        wincmd p " jump back
        if bufname == s:buffer_name
            " if current preview window is context, close it
            pclose
        endif
    endif
endfunction

function! context#toggle() abort
    if g:context_enabled
        call context#disable()
    else
        call context#enable()
    endif
endfunction


function! context#update(force_resize, autocmd) abort
    if !g:context_enabled || !s:activated
        " call s:echof('  disabled')
        return
    endif

    if &previewwindow
        " no context of preview windows (which we use to display context)
        " call s:echof('  abort preview')
        return
    endif

    if mode() != 'n'
        " call s:echof('  abort mode')
        return
    endif

    if type(a:autocmd) == type('') && s:ignore_autocmd
        " ignore nested calls from auto commands
        " call s:echof('  abort from autocmd')
        return
    endif

    call s:echof()
    call s:echof('> update', a:force_resize, a:autocmd)

    let s:ignore_autocmd = 1
    let s:log_indent += 2
    call s:update_context(1, a:force_resize)
    let s:log_indent -= 2
    let s:ignore_autocmd = 0
endfunction

function! context#clear_cache() abort
    " this dictionary maps a line to its next context line
    " so it allows us to skip large portions of the buffer instead of always
    " having to scan through all of it
    let b:context_skips = {}
    let b:context_cost  = 0
    let b:context_saved = 0
endfunction

function! context#cache_stats() abort
    let skips = len(b:context_skips)
    let cost  = b:context_cost
    let total = b:context_cost + b:context_saved
    echom printf('cache: %d skips, %d / %d (%.1f%%)', skips, cost, total, 100.0 * cost / total)
endfunction

function! context#update_padding(autocmd) abort
    " TODO: update in popups too
    " call s:echof('> update_padding', a:autocmd)
    if !g:context_enabled
        return
    endif

    if &previewwindow
        " no context of preview windows (which we use to display context)
        " call s:echof('  abort preview')
        return
    endif

    if mode() != 'n'
        " call s:echof('  abort mode')
        return
    endif

    if s:update_padding()
        " call s:echof('  abort same padding')
        return
    endif

    silent! wincmd P
    if !&previewwindow
        " call s:echof('  abort no preview')
        return
    endif

    if bufname('%') != s:buffer_name
        " call s:echof('  abort different preview')
        wincmd p
        return
    endif

    " call s:echof('  update padding', padding, a:autocmd)
    call s:set_padding(w:padding)
    wincmd p
endfunction


" this function actually updates the context and calls itself until it stabilizes
function! s:update_context(allow_resize, force_resize) abort
    let winid = win_getid()
    let top_line = line('w0')
    let bufnr = bufnr('%')
    let winid = win_getid()
    let popup = get(s:popups, winid, 0)

    call s:echof('> update_context', a:allow_resize, a:force_resize, winid, top_line)

    " TODO: extract function?
    if exists('w:last_top_line')
        let scroll_offset = w:last_top_line - top_line
    else
        let scroll_offset = 1
    endif
    let w:last_top_line = top_line

    if !a:force_resize && s:last_winid == winid && scroll_offset == 0
        " TODO: or maybe just check state of popup windows here?
        " might be too much though
        call s:echof('  abort same win and top line')
        return
    endif

    let s:last_winid = winid
    call s:update_padding()

    let base_line = s:get_base_line(top_line)
    if g:context_presenter == 'preview'
        let min_height = s:get_min_height(a:allow_resize, a:force_resize, scroll_offset)
        let lines = s:get_context_for_preview(base_line, min_height)
    else
        let lines = s:get_context_for_popup(top_line)
    endif

    " limit total context
    let max = g:context_max_height
    if len(lines) > max
        let indent1 = lines[max/2].indent
        let indent2 = lines[-(max-1)/2].indent
        let ellipsis = repeat(g:context_ellipsis_char, max([indent2 - indent1, 3]))
        let ellipsis_line = s:make_line(0, indent1, repeat(' ', indent1) . ellipsis)
        call remove(lines, max/2, -(max+1)/2)
        call insert(lines, ellipsis_line, max/2)
    endif

    " NOTE: this overwrites lines, from here on out it's just a list of string
    call map(lines, function('s:display_line'))

    let s:log_indent += 2
    if g:context_presenter == 'preview'
        call s:show_in_preview(lines)
    else
        call s:show_in_popup(lines)
    endif

    " call again until it stabilizes
    " disallow resizing to make sure it will eventually
    " TODO: don't try again from here, but in one line increments so we
    " actually find the minimum?
    if g:context_presenter == 'preview'
        call s:update_context(0, 0)
    endif

    let s:log_indent -= 2
endfunction

" find first line above (hidden) which isn't empty
" return its indent, -1 if no such line
" TODO: this is expensive now, maybe not do it like this? or limit it somehow?
function! s:get_hidden_indent(top_line, lines) abort
    call s:echof('> get_hidden_indent', a:top_line.number, len(a:lines))
    if len(a:lines) == 0
        " don't show ellipsis if context is empty
        return -1
    endif

    let min_indent = -1
    let max_line = a:lines[-1].number
    let current_line = a:top_line.number - 1 " first hidden line
    while current_line > max_line
        let line = getline(current_line)
        if s:skip_line(line)
            let current_line -= 1
            continue
        endif

        let indent = indent(current_line)
        call s:echof('  got', current_line, max_line, indent, min_indent)
        if min_indent == -1 || min_indent > indent
            let min_indent = indent
        endif

        let current_line -= 1
    endwhile

    call s:echof('  return', min_indent)
    return min_indent
endfunction

" find line downwards (from top line) which isn't empty
function! s:get_base_line(top_line) abort
    let current_line = a:top_line
    while 1
        let indent = indent(current_line)
        if indent < 0 " invalid line
            return s:nil_line
        endif

        let line = getline(current_line)
        if s:skip_line(line)
            let current_line += 1
            continue
        endif

        return s:make_line(current_line, indent, line)
    endwhile
endfunction

function! s:get_context_for_popup(top_line) abort
    " TODO: there's a case where we'd like an "empty" context popup
    " when the `}` of a closing function is on the topline. can we make that
    " work?
    " TODO: check how quickly the context size goes down from line to line. we
    " might be able to shortcut here. for example if the topline has a context
    " of 8 lines, then the line below is likely to have 7 or 8 lines context
    " too. so maybe it's save to skip like 7 lines before we calculate the
    " next context?
    " TODO: there's a problem if some of the hidden lines (below the
    " popup) are wrapped. then our calculations are off...

    " a skipped line has the same context as the next unskipped one below
    let skipped = 0
    let context_count = 0 " how many contexts did we check?
    let line_offset = -1 " first iteration starts with zero

    while 1
        let line_offset += 1
        let line_number = a:top_line + line_offset
        let indent = indent(line_number) "    -1 for invalid lines
        let line = getline(line_number)  " empty for invalid lines
        let base_line = s:make_line(line_number, indent, line)

        if base_line.indent < 0
            let lines = []
        elseif s:skip_line(line)
            let skipped += 1
            continue
        else
            let lines = s:get_context(base_line)
        endif

        let line_count = len(lines)
        " call s:echof('  got', line_offset, line_offset, line_count, skipped)

        if line_count == 0 && context_count == 0
            " if we get an empty context on the first non skipped line
            return []
        endif
        let context_count += 1

        if line_count >= line_offset
            " try again on next line if this context doesn't fit
            let skipped = 0
            continue
        endif

        " success, we found a fitting context
        while len(lines) < line_offset - skipped - 1
            call add(lines, s:nil_line)
        endwhile

        call add(lines, s:get_border_line(base_line))
        return lines
    endwhile
endfunction

function! s:get_context_for_preview(base_line, min_height) abort
    let lines = s:get_context(a:base_line)
    let s:hidden_indent = s:get_hidden_indent(a:base_line, lines)

    while len(lines) < a:min_height
        call add(lines, s:nil_line)
    endwhile
    let w:min_height = len(lines)

    return lines
endfunction

" TODO: reorder functions and split out into autoload dirs
" NOTE: this is preview only
function! s:get_min_height(allow_resize, force_resize, scroll_offset) abort
    " adjust min window height based on scroll amount
    if !exists('w:min_height') || a:force_resize
        return 0
    endif

    if !a:allow_resize || a:scroll_offset == 0
        return w:min_height
    endif

    if !exists('w:resize_level')
        let w:resize_level = 0 " for decreasing window height based on scrolling
    endif

    let diff = abs(a:scroll_offset)
    if diff == 1
        " slowly decrease min height if moving line by line
        let w:resize_level += g:context_resize_linewise
    else
        " quicker if moving multiple lines (^U/^D: decrease by one line)
        let w:resize_level += g:context_resize_scroll / &scroll * diff
    endif

    let t = float2nr(w:resize_level)
    let w:resize_level -= t
    return w:min_height - t
endfunction

" collect all context lines
function! s:get_context(line) abort
    let base_line = a:line
    if base_line.number == 0
        return []
    endif

    let context = {}

    if !exists('b:context_skips')
        let b:context_skips = {}
    endif

    while 1
        let context_line = s:get_context_line(base_line)
        let b:context_skips[base_line.number] = context_line.number " cache this lookup

        if context_line.number == 0
            " join, limit and get context lines
            let lines = []
            for indent in sort(keys(context), 'N')
                let context[indent] = s:join(context[indent])
                let context[indent] = s:limit(context[indent], indent)
                call extend(lines, context[indent])
            endfor
            return lines
        endif

        let indent = context_line.indent
        if !has_key(context, indent)
            let context[indent] = []
        endif

        call insert(context[indent], context_line, 0)

        " for next iteration
        let base_line = context_line
    endwhile
endfunction

function! s:get_context_line(line) abort
    " this is a very primitive way of counting how many lines we scan in total
    " highly unscientific, but can the effect of our caching and where it
    " should be improved
    if !exists('b:context_cost')
        let b:context_cost  = 0
        let b:context_saved = 0
    endif

    " check if we have a skip available from the base line
    let skipped = get(b:context_skips, a:line.number, -1)
    if skipped != -1
        let b:context_saved += a:line.number-1 - skipped
        " call s:echof('  skipped', a:line.number, '->', skipped)
        return s:make_line(skipped, indent(skipped), getline(skipped))
    endif

    " if line starts with closing brace or similar: jump to matching
    " opening one and add it to context. also for other prefixes to show
    " the if which belongs to an else etc.
    if s:extend_line(a:line.text)
        let max_indent = a:line.indent " allow same indent
    else
        let max_indent = a:line.indent - 1 " must be strictly less
    endif

    if max_indent < 0
        return s:nil_line
    endif

    " search for line with matching indent
    let current_line = a:line.number - 1
    while 1
        if current_line <= 0
            " nothing found
            return s:nil_line
        endif

        let b:context_cost += 1

        let indent = indent(current_line)
        if indent > max_indent
            " use skip if we have, next line otherwise
            let skipped = get(b:context_skips, current_line, current_line-1)
            let b:context_saved += current_line-1 - skipped
            let current_line = skipped
            continue
        endif

        let line = getline(current_line)
        if s:skip_line(line)
            let current_line -= 1
            continue
        endif

        return s:make_line(current_line, indent, line)
    endwhile
endfunction

function! s:get_border_line(base_line) abort
    let indent = a:base_line.indent
    let line_len = winwidth(0) - indent - len(s:buffer_name) - 2 - w:padding
    let border = 
                \ repeat(' ', indent) .
                \ repeat(g:context_border_char, line_len) .
                \ ' ' .
                \ s:buffer_name
    return s:make_line(0, indent, border)
endfunction

" https://vi.stackexchange.com/questions/19056/how-to-create-preview-window-to-display-a-string
function! s:open_preview() abort
    call s:echof('> open_preview')
    let settings = '+setlocal'        .
                \ ' buftype=nofile'   .
                \ ' modifiable'       .
                \ ' nobuflisted'      .
                \ ' nocursorline'     .
                \ ' nonumber'         .
                \ ' norelativenumber' .
                \ ' noswapfile'       .
                \ ' nowrap'           .
                \ ' signcolumn=no'    .
                \ ' \|'                                 .
                \ ' let b:airline_disable_statusline=1' .
                \ ''
    execute 'silent! aboveleft pedit' escape(settings, ' ') s:buffer_name
endfunction

function! s:show_in_preview(lines) abort
    call s:echof('> show_in_preview', len(a:lines))

    call s:close_preview()

    if len(a:lines) == 0
        " nothing to do
        call s:echof('  none')
        return
    endif

    let syntax  = &syntax
    let tabstop = &tabstop
    let padding = w:padding

    let s:log_indent += 2
    call s:open_preview()
    let s:log_indent -= 2

    " try to jump to new preview window
    silent! wincmd P
    if !&previewwindow
        " NOTE: apparently this can fail with E242, see #6
        " in that case just silently abort
        call s:echof('  no preview window')
        return
    endif

    silent 0put =a:lines " paste lines
    1                    " and jump to first line

    " TODO: do (some of) this where we create the buffer?
    " or just always refresh?
    execute 'setlocal syntax='  . syntax
    execute 'setlocal tabstop=' . tabstop
    call s:set_padding(padding)

    " resize window
    execute 'resize' len(a:lines)

    wincmd p " jump back
endfunction

function! s:close_preview() abort
    silent! wincmd P " jump to preview, but don't show error
    if !&previewwindow
        return
    endif
    wincmd p

    if &equalalways
        " NOTE: if 'equalalways' is set (which it is by default) then :pclose
        " will change the window layout. here we try to restore the window
        " layout based on some help from /u/bradagy, see
        " https://www.reddit.com/r/vim/comments/e7l4m1
        set noequalalways
        pclose
        let layout = winrestcmd() | set equalalways | noautocmd execute layout
    else
        pclose
    endif
endfunction

" TODO: rename these functions!
" this tries to update w:padding
" returns whether it has changed (needs redraw)
function! s:update_padding() abort
    let padding = wincol() - virtcol('.')
    if padding < 0
        " padding can be negative if cursor was on the wrapped part of a wrapped line
        " in that case don't take the new value

        if !exists('w:padding')
            let w:padding = 0
        endif

        return 0
    endif

    if exists('w:padding') && w:padding == padding
        " same value
        return 0
    endif

    " different value
    let w:padding = padding
    return 1
endfunction

" NOTE: this function updates the statusline too, as it depends on the padding
function! s:set_padding(padding) abort
    execute 'setlocal foldcolumn=' . a:padding

    let statusline = '%=' . s:buffer_name . ' ' " trailing space for padding
    if s:hidden_indent >= 0
        let statusline = repeat(' ', a:padding + s:hidden_indent) . s:ellipsis . statusline
    endif
    execute 'setlocal statusline=' . escape(statusline, ' ')
endfunction


" popup related
" TODO: move to separate file
function! s:show_in_popup(lines) abort
    call s:echof('> show_in_popup', len(a:lines))
    let winid = win_getid()
    let popup = get(s:popups, winid, 0)

    if popup > 0 && !s:popup_valid(popup)
        let popup = 0
        call remove(s:popups, winid)
    endif

    if len(a:lines) == 0
        call s:echof('  no lines')
        if popup > 0
            call s:popup_close(popup)
            call remove(s:popups, winid)
        endif
        return
    endif

    if popup == 0
        let popup = s:popup_open(a:lines, winwidth(0))
        let s:popups[winid] = popup
        return
    endif

    call s:popup_update(popup, a:lines)
endfunction

function! s:popup_open(lines, width) abort
    call s:echof('> popup_open', len(a:lines))
    if g:context_presenter == 'nvim-float'
        let winid = s:nvim_open_popup(a:lines, a:width)
    elseif g:context_presenter == 'vim-popup'
        let winid = s:vim_open_popup(a:lines, a:width)
    endif

    let buf = winbufnr(winid)
    call setbufvar(buf, '&wrap',    0)
    call setbufvar(buf, '&tabstop', &tabstop)
    call setbufvar(buf, '&syntax',  &syntax)

    return winid
endfunction

function! s:popup_update(popup, lines) abort
    call s:echof('> popup_update', len(a:lines))
    if g:context_presenter == 'nvim-float'
        call s:nvim_update_popup(a:popup, a:lines)
    elseif g:context_presenter == 'vim-popup'
        call s:vim_update_popup(a:popup, a:lines)
    endif
endfunction

function! s:popup_close(popup) abort
    call s:echof('> popup_close')
    if g:context_presenter == 'nvim-float'
        call nvim_win_close(a:popup, v:true)
    elseif g:context_presenter == 'vim-popup'
        call popup_close(a:popup)
    endif
endfunction

function! s:popup_clear() abort
    for key in keys(s:popups)
        call s:popup_close(s:popups[key])
    endfor
    let s:popups = {}
endfunction

function! s:popup_valid(popup) abort
    if a:popup == 0
        return 0
    endif

    if g:context_presenter == 'nvim-float'
        return nvim_win_is_valid(a:popup)
    elseif g:context_presenter == 'vim-popup'
        return len(popup_getoptions(a:popup)) > 0
    endif
endfunction

function! s:nvim_open_popup(lines, width) abort
    call s:echof('  > nvim_open_popup', len(a:lines))
    if len(a:lines) == 0
        return
    endif

    let buf = nvim_create_buf(v:false, v:true)
    call nvim_buf_set_lines(buf, 0, -1, v:true, a:lines)
    let opts = {
                \ 'relative':  'win',
                \ 'width':     a:width,
                \ 'height':    len(a:lines),
                \ 'col':       0,
                \ 'row':       0,
                \ 'focusable': v:false,
                \ 'anchor':    'NW',
                \ 'style':     'minimal',
                \ }
    let winid = nvim_open_win(buf, 0, opts)
    " TODO: and/or: add divider line again? might be tricky with syntax highlighting?
    " optional: change highlight, otherwise Pmenu is used
    " TODO: always use long option names
    " NOTE: 'winhighlight' is neovim only
    " TODO: still avoid nvim specific functions like nvim_win_set_option()?
    call nvim_win_set_option(winid, 'winhl', 'Normal:' . g:context_highlight)

    call setbufvar(buf, '&foldcolumn', w:padding)

    return winid
endfunction

function! s:nvim_update_popup(popup, lines) abort
    call s:echof('  > nvim_update_popup', len(a:lines))
    let buf = winbufnr(a:popup)
    " NOTE: this seems to reset the 'foldcolumn' setting
    call nvim_win_set_config(a:popup, {'height': len(a:lines)})
    call nvim_buf_set_lines(buf, 0, -1, v:true, a:lines)

    call setbufvar(buf, '&foldcolumn', w:padding)

    " TODO: bring mode back but only call the open popup function once?
    " NOTE: this redraws the screen. this is needed because there's
    " a redraw issue: https://github.com/neovim/neovim/issues/11597
    " for some reason sometimes it's not enough to :mode once
    " TODO: remove this once that issue has been resolved
    redraw
    mode
endfunction

function! s:vim_open_popup(lines, width) abort
    call s:echof('  > vim_open_popup', len(a:lines))

    " NOTE: popups don't move automatically when windows get resized
    " same for width
    let [line, col] = win_screenpos(0)
    let opts = {
                \ 'line': line,
                \ 'col': col,
                \ 'minwidth': a:width,
                \ 'maxwidth': a:width,
                \ 'wrap': v:false,
                \ }
    let winid = popup_create(a:lines, opts)
    " TODO: use text properties on last line? nvim too similarly
    " NOTE: this option is vim only

	call setwinvar(winid, '&wincolor', g:context_highlight)

	call win_execute(winid, 'set foldcolumn=' . w:padding)

    return winid
endfunction

function! s:vim_update_popup(popup, lines) abort
    call s:echof('  > vim_update_popup', len(a:lines))
    call popup_settext(a:popup, a:lines)

	call win_execute(a:popup, 'set foldcolumn=' . w:padding)
endfunction



" utility functions

function! s:join(lines) abort
    " only works with at least 3 parts, so disable otherwise
    if g:context_max_join_parts < 3
        return a:lines
    endif

    " call s:echof('> join', len(a:lines))
    let pending = [] " lines which might be joined with previous
    let joined = a:lines[:0] " start with first line
    for line in a:lines[1:]
        if s:join_line(line.text)
            " add lines without word characters to pending list
            call add(pending, line)
            continue
        endif

        " don't join lines with word characters
        " but first join pending lines to previous output line
        let joined[-1] = s:join_pending(joined[-1], pending)
        let pending = []
        call add(joined, line)
    endfor

    " join remaining pending lines to last
    let joined[-1] = s:join_pending(joined[-1], pending)
    return joined
endfunction

function! s:join_pending(base, pending) abort
    " call s:echof('> join_pending', len(a:pending))
    if len(a:pending) == 0
        return a:base
    endif

    let max = g:context_max_join_parts
    if len(a:pending) > max-1
        call remove(a:pending, (max-1)/2-1, -max/2-1)
        call insert(a:pending, s:nil_line, (max-1)/2-1) " middle marker
    endif

    let joined = a:base
    for line in a:pending
        let joined.text .= ' '
        if line.number == 0
            " this is the middle marker, use long ellipsis
            let joined.text .= s:ellipsis5
        elseif joined.number != 0 && line.number != joined.number + 1
            " not after middle marker and there are lines in between: show ellipsis
            let joined.text .= s:ellipsis . ' '
        endif

        let joined.text .= s:trim(line.text)
        let joined.number = line.number
    endfor

    return joined
endfunction

function! s:limit(lines, indent) abort
    " call s:echof('> limit', a:indent, len(a:lines))

    let max = g:context_max_per_indent
    if len(a:lines) <= max
        return a:lines
    endif

    let diff = len(a:lines) - max

    let limited = a:lines[: max/2-1]
    call add(limited, s:make_line(0, a:indent, repeat(' ', a:indent) . s:ellipsis))
    call extend(limited, a:lines[-(max-1)/2 :])
    return limited
endif
endfunction

function! s:make_line(number, indent, text) abort
    return {
                \ 'number': a:number,
                \ 'indent': a:indent,
                \ 'text':   a:text,
                \ }
endfunction

function! s:display_line(index, line) abort
    return a:line.text

    " NOTE: comment out the line above to include this debug info
    let n = &columns - 25 - strchars(s:trim(a:line.text)) - a:line.indent
    return printf('%s%s // %2d n:%5d i:%2d', a:line.text, repeat(' ', n), a:index+1, a:line.number, a:line.indent)
endfunction

function! s:extend_line(line) abort
    return a:line =~ g:context_extend_regex
endfunction

function! s:skip_line(line) abort
    return a:line =~ g:context_skip_regex
endfunction

function! s:join_line(line) abort
    return a:line =~ g:context_join_regex
endfunction

function s:trim(string) abort
    return substitute(a:string, '^\s*', '', '')
endfunction

" debug logging, set g:context_logfile to activate
function! s:echof(...) abort
    let args = join(a:000)
    let args = substitute(args, "'", '"', 'g')
    let args = substitute(args, '!', '^', 'g')
    let message = repeat(' ', s:log_indent) . args

    " echom message
    if exists('g:context_logfile')
        execute "silent! !echo '" . message . "' >>" g:context_logfile
    endif
endfunction
