let s:query_instance = {}
let s:query = {}

function! db_ui#query#new(drawer) abort
  let s:query_instance = s:query.new(a:drawer)
  return s:query_instance
endfunction

function! s:query.new(drawer) abort
  let instance = copy(self)
  let instance.drawer = a:drawer
  let instance.buffer_counter = {}
  let instance.last_query = []
  return instance
endfunction

function! s:query.open(item, edit_action) abort
  let db = self.drawer.dbui.dbs[a:item.dbui_db_key_name]
  if a:item.type ==? 'buffer'
    return self.open_buffer(db, a:item.file_path, a:edit_action)
  endif
  let suffix = 'query'
  let table = ''
  let schema = ''
  if a:item.type !=? 'query'
    let suffix = a:item.table.'-'.a:item.label
    let table = a:item.table
    let schema = a:item.schema
  endif

  let buffer_name = printf('%s.%s', tempname(), self.generate_buffer_basename(db.name, suffix))
  call self.open_buffer(db, buffer_name, a:edit_action, {'table': table, 'content': get(a:item, 'content'), 'is_tmp': 1, 'schema': schema })
endfunction

function! s:query.generate_buffer_basename(db_name, suffix) abort
  let buffer_basename = db_ui#utils#slug(printf('%s-%s', a:db_name, a:suffix))
  if !has_key(self.buffer_counter, buffer_basename)
    let self.buffer_counter[buffer_basename] = 1
    return buffer_basename
  endif

  let new_name = buffer_basename.'-'.self.buffer_counter[buffer_basename]
  let self.buffer_counter[buffer_basename] += 1
  return new_name
endfunction

function! s:query.focus_window() abort
  let win_pos = g:dbui_win_position ==? 'left' ? 'botright' : 'topleft'
  let win_cmd = 'vertical '.win_pos.' new'
  if winnr('$') ==? 1
    silent! exe win_cmd
    return
  endif

  let found = 0
  for win in range(1, winnr('$'))
    let buf = winbufnr(win)
    if !empty(getbufvar(buf, 'dbui_db_key_name'))
      let found = 1
      exe win.'wincmd w'
      break
    endif
  endfor

  if !found
    for win in range(1, winnr('$'))
      if getwinvar(win, '&filetype') !=? 'dbui' && getwinvar(win, '&buftype') !=? 'nofile'
        let found = 1
        exe win.'wincmd w'
        break
      endif
    endfor
  endif

  if (!found)
    silent! exe win_cmd
  endif
endfunction

function s:query.open_buffer(db, buffer_name, edit_action, ...)
  let opts = get(a:, '1', {})
  let table = get(opts, 'table', '')
  let schema = get(opts, 'schema', '')
  let default_content = get(opts, 'content', g:dbui_default_query)
  let was_single_win = winnr('$') ==? 1

  if a:edit_action ==? 'edit'
    call self.focus_window()
    let bufnr = bufnr(a:buffer_name)
    if bufnr > -1
      silent! exe 'b '.bufnr
      call self.setup_buffer(a:db, opts, a:buffer_name, was_single_win)
      return
    endif
  endif

  silent! exe a:edit_action.' '.a:buffer_name
  call self.setup_buffer(a:db, opts, a:buffer_name, was_single_win)

  if empty(table)
    return
  endif

  let optional_schema = schema ==? a:db.default_scheme ? '' : schema

  if !empty(optional_schema)
    if a:db.quote
      let optional_schema = '"'.optional_schema.'"'
    endif
    let optional_schema = optional_schema.'.'
  endif

  let b:dbui_table_name = table
  let content = substitute(default_content, '{table}', table, 'g')
  let content = substitute(content, '{optional_schema}', optional_schema, 'g')
  let content = substitute(content, '{schema}', schema, 'g')
  let db_name = !empty(schema) ? schema : a:db.name
  let content = substitute(content, '{dbname}', db_name, 'g')
  let content = substitute(content, '{last_query}', join(self.last_query, "\n"), 'g')
  silent 1,$delete _
  call setline(1, split(content, "\n"))
  if g:dbui_auto_execute_table_helpers
    write
  endif
endfunction

function! s:query.setup_buffer(db, opts, buffer_name, was_single_win) abort
  call self.resize_if_single(a:was_single_win)
  let b:dbui_db_key_name = a:db.key_name
  let b:db = a:db.conn
  if !exists('b:dbui_is_tmp') || has_key(a:opts, 'is_tmp')
    let b:dbui_is_tmp = get(a:opts, 'is_tmp', 0)
  endif
  let db_buffers = self.drawer.dbui.dbs[a:db.key_name].buffers

  if index(db_buffers.list, a:buffer_name) ==? -1
    if empty(db_buffers.list)
      let db_buffers.expanded = 1
    endif
    call add(db_buffers.list, a:buffer_name)
    call self.drawer.render()
  endif

  setlocal filetype=sql nolist noswapfile nowrap cursorline nospell modifiable
  nnoremap <buffer><Plug>(DBUI_EditBindParameters) :call <sid>method('edit_bind_parameters')<CR>
  nnoremap <buffer><Plug>(DBUI_ExecuteQuery) :call <sid>method('execute_query')<CR>
  vnoremap <buffer><Plug>(DBUI_ExecuteQuery) :<C-u>call <sid>method('execute_query', 1)<CR>
  if b:dbui_is_tmp
    nnoremap <buffer><silent><Plug>(DBUI_SaveQuery) :call <sid>method('save_query')<CR>
  endif
  augroup db_ui_query
    autocmd! * <buffer>
    autocmd BufWritePost <buffer> nested call s:method('execute_query')
    autocmd BufDelete,BufWipeout <buffer> silent! call s:method('remove_buffer', str2nr(expand('<abuf>')))
  augroup END
endfunction

function! s:method(name, ...) abort
  if a:0 > 0
    return s:query_instance[a:name](a:1)
  endif

  return s:query_instance[a:name]()
endfunction

function! s:query.resize_if_single(is_single_win) abort
  if a:is_single_win
    exe bufwinnr('dbui').'wincmd w'
    exe 'vertical resize '.g:dbui_winwidth
    wincmd p
  endif
endfunction

function! s:query.remove_buffer(bufnr)
  let dbui_db_key_name = getbufvar(a:bufnr, 'dbui_db_key_name')
  let list = self.drawer.dbui.dbs[dbui_db_key_name].buffers.list
  call filter(list, 'v:val !=? bufname(a:bufnr)')
  return self.drawer.render()
endfunction

function! s:query.execute_query(...) abort
  let lines = self.get_lines(get(a:, 1, 0))
  let query_time = reltime()
  call db_ui#utils#echo_msg('Executing query...')
  let db = self.drawer.dbui.dbs[b:dbui_db_key_name]
  if match(join(lines), '[^:]:\w\+') > -1
    call self.inject_variables_and_execute(db, copy(lines))
  else
    silent! exe 'DB '.join(lines)
  endif
  let self.last_query = lines
  call db_ui#utils#echo_msg('Executing query...Done after '.split(reltimestr(reltime(query_time)))[0].' sec.')
endfunction


function! s:query.get_lines(is_visual_mode) abort
  if !a:is_visual_mode
    return getline(1, '$')
  endif

  let sel_save = &selection
  let &selection = 'inclusive'
  let reg_save = @@
  silent exe 'normal! gvy'
  let lines = split(@@, "\n")
  let &selection = sel_save
  let @@ = reg_save
  return lines
endfunction

function! s:query.inject_variables_and_execute(db, lines) abort
  let vars = []
  for line in a:lines
    call substitute(line, '[^:]\(:\w\+\)', '\=add(vars, submatch(1))', 'g')
  endfor

  if !exists('b:dbui_bind_params')
    let b:dbui_bind_params = {}
  endif

  let existing_vars = keys(b:dbui_bind_params)
  let needs_prompt = !empty(filter(copy(vars), 'index(existing_vars, v:val) <= -1'))
  if needs_prompt
    echo "Please provide bind parameters. Empty values are ignored and considered a raw value.\n\n"
  endif

  for var in vars
    if !has_key(b:dbui_bind_params, var)
      let b:dbui_bind_params[var] = db_ui#utils#input('Enter value for bind parameter '.var.' -> ', '')
    endif
  endfor

  let content = join(a:lines)

  for [var, val] in items(b:dbui_bind_params)
    if trim(val) ==? ''
      continue
    endif

    let content = substitute(content, var, db_ui#utils#quote_query_value(val), 'g')
  endfor

  exe 'DB '.a:db.conn.' '.content
  call db_ui#utils#echo_msg('Executing query...Done.')
endfunction

function! s:query.edit_bind_parameters() abort
  if !exists('b:dbui_bind_params') || empty(b:dbui_bind_params)
    return db_ui#utils#echo_msg('No bind parameters to edit.')
  endif

  let variable_names = keys(b:dbui_bind_params)
  let opts = ['Select bind parameter to edit/delete:'] + map(copy(variable_names), '(v:key + 1).") ".v:val." (".(trim(b:dbui_bind_params[v:val]) ==? "" ? "Not provided" : b:dbui_bind_params[v:val]).")"')
  let selection = db_ui#utils#inputlist(opts)

  if selection < 1 || selection > len(variable_names)
    return db_ui#utils#echo_err('Wrong selection.')
  endif

  let var_name = variable_names[selection - 1]
  let variable = b:dbui_bind_params[var_name]
  redraw!
  let action = confirm('Select action for '.var_name.'? ', "&Edit\n&Delete\n&Cancel")
  if action ==? 1
    redraw!
    let b:dbui_bind_params[var_name] = db_ui#utils#input('Enter new value: ', variable)
    return db_ui#utils#echo_msg('Changed.')
  endif

  if action ==? 2
    unlet b:dbui_bind_params[var_name]
    return db_ui#utils#echo_msg('Deleted.')
  endif

  return db_ui#utils#echo_msg('Canceled')
endfunction

function! s:query.save_query() abort
  let db = self.drawer.dbui.dbs[b:dbui_db_key_name]
  if empty(db.save_path)
    throw 'Save location is empty. Please provide valid directory to g:db_ui_save_location'
  endif

  if !isdirectory(db.save_path)
    call mkdir(db.save_path, 'p')
  endif

  let name = db_ui#utils#input('Save as: ', '')

  let full_name = printf('%s/%s', db.save_path, name)
  if filereadable(full_name)
    throw 'That file already exists. Please choose another name.'
  endif

  exe 'write '.full_name
  call self.drawer.render({ 'queries': 1 })
endfunction
