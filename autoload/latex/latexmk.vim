" {{{1 latex#latexmk#init
function! latex#latexmk#init(initialized)
  if !g:latex_latexmk_enabled | return | endif

  "
  " Check if system is incompatible with latexmk
  "
  if s:system_incompatible() | return | endif

  "
  " Initialize pid for current tex file
  "
  if !has_key(g:latex#data[b:latex.id], 'pid')
    let g:latex#data[b:latex.id].pid = 0
  endif

  "
  " Set default mappings
  "
  if g:latex_mappings_enabled
    nnoremap <silent><buffer> <localleader>ll :call latex#latexmk#compile()<cr>
    nnoremap <silent><buffer> <localleader>lc :call latex#latexmk#clean()<cr>
    nnoremap <silent><buffer> <localleader>lC :call latex#latexmk#clean(1)<cr>
    nnoremap <silent><buffer> <localleader>lg :call latex#latexmk#status()<cr>
    nnoremap <silent><buffer> <localleader>lG :call latex#latexmk#status(1)<cr>
    nnoremap <silent><buffer> <localleader>lk :call latex#latexmk#stop(1)<cr>
    nnoremap <silent><buffer> <localleader>lK :call latex#latexmk#stop_all()<cr>
    nnoremap <silent><buffer> <localleader>le :call latex#latexmk#errors(1)<cr>
  endif

  "
  " Ensure that all latexmk processes are stopped when vim exits
  " Note: Only need to define this once, globally.
  "
  if !a:initialized
    augroup latex_latexmk
      autocmd!
      autocmd VimLeave *.tex call latex#latexmk#stop_all()
    augroup END
  endif

  "
  " If all buffers for a given latex project are closed, kill latexmk
  " Note: This must come after the above so that the autocmd group is properly
  "       refreshed if necessary
  "
  augroup latex_latexmk
    autocmd BufUnload <buffer> call s:stop_buffer()
  augroup END
endfunction

" {{{1 latex#latexmk#clean
function! latex#latexmk#clean(...)
  let full = a:0 > 0

  let data = g:latex#data[b:latex.id]
  if data.pid
    echomsg "latexmk is already running"
    return
  endif

  "
  " Run latexmk clean process
  "
  if has('win32')
    let cmd = 'cd /D ' . shellescape(data.root) . ' & '
  else
    let cmd = 'cd ' . shellescape(data.root) . ';'
  endif
  if full
    let cmd .= 'latexmk -C '
  else
    let cmd .= 'latexmk -c '
  endif
  let cmd .= shellescape(data.base)
  let g:latex#data[b:latex.id].clean_cmd = cmd
  let exe = {
        \ 'cmd' : cmd,
        \ 'bg'  : 0,
        \ }
  call latex#util#execute(exe)

  if full
    echomsg "latexmk full clean finished"
  else
    echomsg "latexmk clean finished"
  endif
endfunction

" {{{1 latex#latexmk#compile
function! latex#latexmk#compile()
  let data = g:latex#data[b:latex.id]
  if data.pid
    echomsg "latexmk is already running for `" . data.base . "'"
    return
  endif

  call s:latexmk_set_cmd(data)

  " Start latexmk
  " Define execute dictionary and latexmk command
  let exe = {}
  let exe.null = 0
  let exe.cmd  = data.cmd
  call latex#util#execute(exe)

  " Save PID
  call s:latexmk_set_pid(data)

  " Finished
  echomsg 'latexmk started successfully'
endfunction

" }}}1
" {{{1 latex#latexmk#errors
function! latex#latexmk#errors(force)
  cclose

  let log = g:latex#data[b:latex.id].log()
  if empty(log)
    if a:force
      echo "No log file found!"
    endif
    return
  endif

  if g:latex_quickfix_autojump
    execute 'cfile ' . log
  else
    execute 'cgetfile ' . log
  endif

  "
  " There are two options that determine when to open the quickfix window.  If
  " forced, the quickfix window is always opened when there are errors or
  " warnings (forced typically imply that the functions is called from the
  " normal mode mapping).  Else the behaviour is based on the settings.
  "
  let open_quickfix_window = a:force
        \ || (g:latex_quickfix_mode > 0
        \     && (g:latex_quickfix_open_on_warning
        \         || s:log_contains_error(log)))

  if open_quickfix_window
    botright cwindow
    if g:latex_quickfix_mode == 2
      wincmd p
    endif
    redraw!
  endif
endfunction

" {{{1 latex#latexmk#status
function! latex#latexmk#status(...)
  let detailed = a:0 > 0

  if detailed
    let running = 0
    for data in g:latex#data
      if data.pid
        if !running
          echo "latexmk is running"
          let running = 1
        endif

        let name = data.tex
        if len(name) >= winwidth('.') - 20
          let name = "..." . name[-winwidth('.')+23:]
        endif

        echom printf('pid: %6s, file: %-s', data.pid, name)
      endif
    endfor

    if !running
      echo "latexmk is not running"
    endif
  else
    if g:latex#data[b:latex.id].pid
      echo "latexmk is running"
    else
      echo "latexmk is not running"
    endif
  endif
endfunction

" {{{1 latex#latexmk#stop
function! latex#latexmk#stop(...)
  let l:verbose = a:0 > 0

  let pid  = g:latex#data[b:latex.id].pid
  let base = g:latex#data[b:latex.id].base
  if pid
    call s:latexmk_kill_pid(pid)
    let g:latex#data[b:latex.id].pid = 0
    if l:verbose
      echo "latexmk stopped for `" . base . "'"
    endif
  elseif l:verbose
    echo "latexmk is not running for `" . base . "'"
  endif
endfunction

" }}}1
" {{{1 latex#latexmk#stop_all
function! latex#latexmk#stop_all()
  for data in g:latex#data
    if data.pid
      call s:latexmk_kill_pid(data.pid)
      let data.pid = 0
    endif
  endfor
endfunction

" }}}1

" Helper functions for latexmk command
" {{{1 s:latexmk_set_cmd
function! s:latexmk_set_cmd(data)
  " Note: We don't send output to /dev/null, but rather to a temporary file,
  "       which allows inspection of latexmk output
  let tmp = tempname()

  if has('win32')
    let cmd  = 'cd /D ' . shellescape(a:data.root)
    let cmd .= ' && set max_print_line=2000 & latexmk'
  else
    let cmd  = 'cd ' . shellescape(a:data.root)
    let cmd .= ' && max_print_line=2000 latexmk'
  endif

  let cmd .= ' -' . g:latex_latexmk_output
  let cmd .= ' -quiet '
  let cmd .= ' -pvc'
  let cmd .= ' ' . g:latex_latexmk_options
  let cmd .= ' -e ' . shellescape('$pdflatex =~ s/ / -file-line-error /')
  let cmd .= ' -e ' . shellescape('$latex =~ s/ / -file-line-error /')

  if g:latex_latexmk_callback && has('clientserver')
    let callback = 'vim --servername ' . v:servername
          \ . ' --remote-expr ''latex\#latexmk\#errors(0)'''
    let cmd .= ' -e ' . shellescape('$success_cmd .= "' . callback . '"')
          \ .  ' -e ' . shellescape('$failure_cmd .= "' . callback . '"')
  endif

  let cmd .= ' ' . shellescape(a:data.base)

  if has('win32')
    let cmd .= ' >'  . tmp
    let cmd = 'cmd /s /c "' . cmd . '"'
  else
    let cmd .= ' &>' . tmp
  endif

  let a:data.cmd = cmd
  let a:data.tmp = tmp
endfunction

" }}}1
" {{{1 s:latexmk_set_pid
function! s:latexmk_set_pid(data)
  if has('win32')
    let tmpfile = tempname()
    silent execute '!cmd /c "wmic process where '
          \ . '(CommandLine LIKE "latexmk\%' . a:data.base . '\%") '
          \ . 'get ProcessId /value | find "ProcessId" '
          \ . '>' . tmpfile . ' "'
    let pids = readfile(tmpfile)
    let a:data.pid = strpart(pids[0], 10)
  else
    let a:data.pid = system('pgrep -nf "^perl.*latexmk"')[:-2]
  endif
endfunction

" }}}1
" {{{1 s:latexmk_kill_pid
function! s:latexmk_kill_pid(pid)
  let exe = {}
  let exe.bg = 0
  let exe.null = 0

  if has('win32')
    let exe.cmd = 'taskkill /PID ' . a:pid . ' /T /F'
  else
    let exe.cmd = 'kill ' . a:pid
  endif

  call latex#util#execute(exe)
endfunction

" }}}1

" {{{1 s:log_contains_error
function! s:log_contains_error(logfile)
  let lines = readfile(a:logfile)
  let lines = filter(lines, 'v:val =~ ''^.*:\d\+: ''')
  let lines = uniq(map(lines, 'matchstr(v:val, ''^.*\ze:\d\+:'')'))
  let lines = map(lines, 'fnameescape(fnamemodify(v:val, '':p''))')
  let lines = filter(lines, 'filereadable(v:val)')
  return len(lines) > 0
endfunction

" {{{1 s:stop_buffer
function! s:stop_buffer()
  "
  " Only run if latex variables are set
  "
  if !exists('b:latex') | return | endif
  let id = b:latex.id
  let pid = g:latex#data[id].pid

  "
  " Only stop if latexmk is running
  "
  if pid
    "
    " Count the number of buffers that point to current latex blob
    "
    let n = 0
    for b in filter(range(1, bufnr("$")), 'buflisted(v:val)')
      if id == getbufvar(b, 'latex', {'id' : -1}).id
        let n += 1
      endif
    endfor

    "
    " Only stop if current buffer is the last for current latex blob
    "
    if n == 1
      call latex#latexmk#stop(0)
    endif
  endif
endfunction

" {{{1 s:system_incompatible()
function! s:system_incompatible()
  if has('win32')
    let required = ['latexmk']
  else
    let required = ['latexmk', 'pgrep']
  endif

  "
  " Check for required executables
  "
  for cmd in required
    if !executable(cmd)
      echom "Warning: Could not initialize latex#latexmk"
      echom "         Missing executable: " . cmd
      return 1
    endif
  endfor
endfunction

" }}}1

" vim: fdm=marker
