vim9script

import autoload 'utils/selector.vim'
import autoload 'utils/devicons.vim'

var last_result_len: number
var cur_pattern: string
var last_pattern: string
var in_loading: number
var cwd: string
var cwdlen: number
var cur_result: list<string>
var jid: job
var menu_wid: number
var files_update_tid: number
var cache: dict<any>
var matched_hl_offset = 0
var devicon_char_width = devicons.GetDeviconCharWidth()

var commands: dict<any>

def InsideGitRepo(): bool
    return stridx(system('git rev-parse --is-inside-work-tree'), 'true') == 0
enddef

var max_count = 1000
var rg_cmd = 'rg --column -M200 --vimgrep --max-count=' .. max_count .. ' "%s" "%s"'
var ag_cmd = 'ag --column -W200 --vimgrep --max-count=' .. max_count .. ' "%s" "%s"'
var grep_cmd = 'grep -n -r --max-count=' .. max_count .. ' "%s" "%s"'
var sep_pattern = '\:\d\+:\d\+:'

var cmdstr: string
if executable('ag')
    cmdstr = ag_cmd
elseif executable('grep')
    cmdstr = grep_cmd
    sep_pattern = '\:\d\+:'
elseif executable('rg')
    # not sure why rg has bad delay using job_start
    cmdstr = rg_cmd
endif

def GetOrDefault(name: string, default: any): any
    if exists(name)
        return eval(name)
    endif
    return default
enddef

def ProcessResult(list_raw: list<string>, ...args: list<any>): list<string>
    var limit = -1
    var li: list<string>
    if len(args) > 0
        li = list_raw[: args[0]]
    else
        li = list_raw
    endif
    return li
enddef

def Select(wid: number, result: list<any>)
    var path = result[0]
    var action = 'edit '
    if len(result) > 1
        var key = result[1]
        if key == "\<CR>" # current window
            action = 'edit '
        elseif key == "\<c-t>" # new tab
            action = 'tabnew '
        elseif key == "\<c-v>" # vertical split
            action = 'vsp '
        elseif key == "\<c-s>" # split
            action = 'sp '
        endif
    endif
    execute(action .. path)
enddef

def AsyncCb(result: list<any>)
    var strs = []
    var hl_list = []
    var idx = 1
    for item in result
        add(strs, item[0])
        hl_list += reduce(item[1], (acc, val) => {
            var pos = copy(val)
            pos[0] += matched_hl_offset
            add(acc, [idx] + pos)
            return acc
        }, [])
        idx += 1
    endfor
    selector.UpdateMenu(ProcessResult(strs), hl_list)
enddef

def Input(wid: number, val: dict<any>, ...li: list<any>)
    var pattern = val.str
    cur_pattern = pattern

    # when in loading state, files_update_menu will handle the input
    if in_loading
        return
    endif

    var file_list = cur_result

    if pattern != ''
        selector.FuzzySearchAsync(cur_result, cur_pattern, 200, function('AsyncCb'))
    else
        selector.UpdateMenu(ProcessResult(cur_result, 100), [])
        popup_setoptions(menu_wid, {'title': len(cur_result)})
    endif

enddef

var cur_menu_item = ''
var preview_wid = -1
var cur_dict = {}

# return:
#   [path, linenr]
def ParseAgStr(str: string): list<any>
    var seq = matchstrpos(str, sep_pattern)
    if seq[1] == -1
        return [v:null, -1, -1]
    endif
    # var path = str[: seq[1] - 1]
    var path = strpart(str, 0, seq[1])
    var linecol = split(seq[0], ':')
    var line = str2nr(linecol[0])
    var col: number
    if len(linecol) == 2
        col = str2nr(linecol[1])
    else
        col = 0
    endif
    return [path, line, col]
enddef

def UpdatePreviewHl()
    if !has_key(cur_dict, cur_menu_item)
        return
    endif
    var [path, linenr, colnr] = ParseAgStr(cur_menu_item)
    clearmatches(preview_wid)
    var hl_list = [cur_dict[cur_menu_item]]
    matchaddpos('cursearch', hl_list, 9999, -1,  {'window': preview_wid})
enddef

def Preview(wid: number, opts: dict<any>)
    var result = opts.cursor_item
    var last_item = opts.last_cursor_item
    var [path, linenr, colnr] = ParseAgStr(result)
    var last_path: string
    var last_linenr: number
    if type(last_item) == v:t_string  && type(last_item) == v:t_string && last_item != ''
        try
        [last_path, last_linenr, _] = ParseAgStr(last_item)
        catch
            return
        endtry
    else
        [last_path, last_linenr] = ['', -1]
    endif
    cur_menu_item = result

    if !path || !filereadable(path)
        if path == v:null
            popup_settext(preview_wid, '')
        else
            popup_settext(preview_wid, '"' .. path .. '" not found')
        endif
        return
    endif

    if path != last_path
        var preview_bufnr = winbufnr(preview_wid)
        var fileraw = readfile(path)
        var ext = fnamemodify(path, ':e')
        var ft = selector.GetFt(ext)
        popup_settext(preview_wid, fileraw)
        # set syntax won't invoke some error cause by filetype autocmd
        try
            setbufvar(preview_bufnr, '&syntax', ft)
        catch
        endtry
    endif
    if path != last_path || linenr != last_linenr
        win_execute(preview_wid, 'norm ' .. linenr .. 'G')
        win_execute(preview_wid, 'norm! zz')
    endif
    UpdatePreviewHl()
enddef

def FilesJobStart(path: string, args: string)
    if type(jid) == v:t_job && job_status(jid) == 'run'
        job_stop(jid)
    endif
    cur_result = []
    if path == ''
        return
    endif
    if cmdstr == ''
        in_loading = 0
        cur_result += glob(cwd .. '/**', 1, 1, 1)
        selector.UpdateMenu(ProcessResult(cur_result), [])
        return
    endif
    var cmd_str = printf(cmdstr, args, path)
    jid = job_start(cmd_str, {
        out_cb: function('JobHandler'),
        out_mode: 'raw',
        exit_cb: function('ExitCb'),
        err_cb: function('ErrCb'),
        cwd: path
    })
enddef

def ErrCb(channel: channel, msg: string)
    # echom ['err']
enddef

def ExitCb(j: job, status: number)
    in_loading = 0
    timer_stop(files_update_tid)
	if last_result_len <= 0
        selector.UpdateMenu(ProcessResult(cur_result, 100), [])
	endif
    popup_setoptions(menu_wid, {'title': len(cur_result)})
enddef

def JobHandler(channel: channel, msg: string)
    var lists = selector.Split(msg)
    cur_result += lists
enddef

def Profiling()
    profile start ~/.vim/vim.log
    profile func Input
    profile func Reducer
    profile func Preview
    profile func JobHandler
    profile func FilesUpdateMenu
enddef

def FilesUpdateMenu(...li: list<any>)
    var cur_result_len = len(cur_result)
    popup_setoptions(menu_wid, {'title': string(len(cur_result))})
    # if cur_result_len == last_result_len
        # return
    # endif
    last_result_len = cur_result_len

        if cur_pattern != last_pattern
            selector.FuzzySearchAsync(cur_result, cur_pattern, 200, function('AsyncCb'))
            # if cur_pattern == ''
                selector.UpdateMenu(ProcessResult(cur_result, 100), [])
            # endif
            last_pattern = cur_pattern
        endif
enddef

def Close(wid: number, opts: dict<any>)
    if type(jid) == v:t_job && job_status(jid) == 'run'
        job_stop(jid)
    endif
    timer_stop(files_update_tid)
enddef

export def AgStart(args: string)
    last_result_len = -1
    cur_result = []
    cur_pattern = ''
    last_pattern = '@!#-='
    cwd = getcwd()
    cwdlen = len(cwd)
    in_loading = 1
    var winds = selector.Start([], {
        select_cb:  function('Select'),
        preview_cb:  function('Preview'),
        input_cb:  function('Input'),
        close_cb:  function('Close'),
        preview:  1,
        scrollbar: 0,
        # prompt: pathshorten(fnamemodify(cwd, ':~' )) .. (has('win32') ? '\ ' : '/ '),
    })
    FilesJobStart(cwd, args)
    #var info_wid = winds[3]
    #popup_settext(info_wid, 'cwd: ' .. fnamemodify(cwd, ':~' ) .. (has('win32') ? '\ ' : '/ '))
    menu_wid = winds[0]
    preview_wid = winds[2]
    timer_start(50, function('FilesUpdateMenu'))
    files_update_tid = timer_start(400, function('FilesUpdateMenu'), {'repeat': -1})
    # Profiling()
enddef
