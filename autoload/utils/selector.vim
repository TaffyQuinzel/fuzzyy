vim9script

import './popup.vim'
import './devicons.vim'

var fzf_list: list<string>
var cwd: string
var menu_wid: number
var prompt_str: string
var matched_hl_offset = 0
var enable_devicons = exists('g:fuzzyy_devicons') && exists('g:WebDevIconsGetFileTypeSymbol') ?
    g:fuzzyy_devicons : exists('g:WebDevIconsGetFileTypeSymbol')

if enable_devicons
    matched_hl_offset = devicons.GetDeviconWidth() + 1
endif
export var windows: dict<any>

var filetype_table = {
    h:  'c',
    hpp:  'cpp',
    cc:  'cpp',
    hh:  'cpp',
    py:  'python',
    js:  'javascript',
    ts:  'typescript',
    tsx:  'typescript',
    jsx:  'typescript',
    rs:  'rust',
    json:  'json',
    yml:  'yaml',
    md:  'markdown',
}

var enable_dropdown = exists('g:fuzzyy_dropdown') ? g:fuzzyy_dropdown : 0

# This function is used to render the menu window.
# params:
# - str_list: list of string to be displayed in the menu window
# - hl_list: list of highlight positions
export def UpdateMenu(str_list: list<string>, hl_list: list<list<any>>)
    popup.MenuSetText(menu_wid, str_list)
    popup.MenuSetHl('select', menu_wid, hl_list)
    if enable_devicons
        devicons.AddColor(menu_wid)
    endif
enddef

export def MenuGetCursorItem(): string
    var bufnr = winbufnr(windows.menu)
    var cursorlinepos = line('.', windows.menu)
    return getbufline(bufnr, cursorlinepos, cursorlinepos)[0]
enddef

export def Split(str: string): list<string>
    var sep: string
    if has('win32') && stridx(str, "\r\n") >= 0
        sep = '\r\n'
    else
        sep = '\n'
    endif
    return split(str, sep)
enddef

export def GetFt(ft: string): string
    if has_key(filetype_table, ft)
        return filetype_table[ft]
    endif
    return ft
enddef

# if pattern is empty, return [li, []]
# params:
#  - li: list of string to be searched
#  - pattern: string to be searched
#  - args: dict of options
#      - limit: max number of results
# return:
# - a list [str_list, hl_list]
#   - str_list: list of string to be displayed
#   - hl_list: list of highlight positions
#       - [[line1, col1], [line1, col2], [line2, col1], ...]
export def FuzzySearch(li: list<string>, pattern: string, ...args: list<any>): list<any>
    if pattern == ''
        return [copy(li), []]
    endif
    var opts = {}
    if len(args) > 0 && args[0] > 0
        opts['limit'] = args[0]
    endif
    var results: list<any> = matchfuzzypos(li, pattern, opts)
    var strs = results[0]
    var poss = results[1]
    var scores = results[2]

    var str_list = []
    var hl_list = []
    for idx in range(0, len(strs) - 1)
        add(str_list, strs[idx])
        var poss_result = MergeContinusNumber(poss[idx])
        hl_list += reduce(poss_result, (acc, val) => add(acc, [idx + 1] + val), [])
    endfor
    return [str_list, hl_list]
enddef

var async_list: list<string>
var async_limit: number
var async_pattern: string
var async_exclude: list<string>
var async_results: list<any>
var async_tid: number
var AsyncCb: func

# merge continus numbers and convert than from string index to vim column
# eg. [1,2,3,4,5,7,9] -> [[1,5], [7], [9]]
def MergeContinusNumber(li: list<number>): list<any>
    var last_pos = li[0]
    var start_pos = li[0]
    var pos_len = 1
    var poss_result = []
    for idx in range(1, len(li) - 1)
        var pos = li[idx]
        if pos == last_pos + 1
            pos_len += 1
        else
            # add 1 because vim column starts from 1 and string index starts from 0
            if pos_len > 1
                add(poss_result, [start_pos + 1, pos_len])
            else
                add(poss_result, [start_pos + 1])
            endif
            start_pos = pos
            last_pos = pos
            pos_len = 1
        endif
        last_pos = pos
    endfor
    if pos_len > 1
        add(poss_result, [start_pos + 1, pos_len])
    else
        add(poss_result, [start_pos + 1])
    endif
    return poss_result
enddef

def Worker(tid: number)
    const ASYNC_STEP = 1000
    var li = async_list[: ASYNC_STEP]
    var cleaned_pattern: list<string>
    for s in split(async_pattern)
        if s[0] == '!'
            add(async_exclude, s[1 : ])
        else
            add(cleaned_pattern, s)
        endif
    endfor
    async_pattern = join(cleaned_pattern)

    var results: list<any> = matchfuzzypos(li, async_pattern)
    var processed_results = []
    var split_pattern = split(async_pattern)
    var ignore_list = map(filter(split_pattern, (_, v) => v[0] == '!'), (_, v) => v[1 : ])

    var strs = results[0]
    var poss = results[1]
    var scores = results[2]
    for idx in range(len(strs))
        var s = strs[idx]
        var found = false
        for excl in async_exclude
            if match(s, excl) != -1
                found = true
                break
            endif
        endfor
        if found
            continue
        else
            # merge continus number
            var poss_result = MergeContinusNumber(poss[idx])
            add(processed_results, [s, poss_result, scores[idx]])
        endif
    endfor
    async_results += processed_results
    sort(async_results, (a, b) => {
        if a[2] < b[2]
            return 1
        elseif a[2] > b[2]
            return -1
        else
            return a[0] > b[0] ? 1 : -1
        endif
    })

    if len(async_results) >= async_limit
        async_results = async_results[: async_limit]
    endif
    AsyncCb(async_results)

    async_list = async_list[ASYNC_STEP + 1 :]
    if len(async_results) >= async_limit || len(async_list) == 0
        timer_stop(tid)
        return
    endif
enddef

# Using timer to mimic async search. This is a workaround for the lack of async
# support in vim. It uses timer to do the search in the background, and calls
# the callback function when part of the results are ready.
# This function only allows one outstanding call at a time. If a new call is
# made before the previous one finishes, the previous one will be canceled.
# params:
#  - li: list of string to be searched
#  - pattern: string to be searched
#  - limit: max number of results
#  - Cb: callback function
# return:
#  timer id
export def FuzzySearchAsync(li: list<string>, pattern: string, limit: number, Cb: func): number
    # only one outstanding call at a time
    timer_stop(async_tid)
    if pattern == ''
        return -1
    endif
    async_list = li
    async_limit = limit
    async_pattern = pattern
    async_exclude = []
    async_results = []
    AsyncCb = Cb
    async_tid = timer_start(50, function('Worker'), {'repeat': -1})
    Worker(async_tid)
    return async_tid
enddef

export def GetPrompt(): string
    return prompt_str
enddef

def Input(wid: number, args: dict<any>, ...li: list<any>)
    var val = args.str
    prompt_str = val
    var hl_list = []
    menu_wid = args.win_opts.partids.menu
    var ret: list<string>
    [ret, hl_list] = FuzzySearch(fzf_list, val)

    if enable_devicons
         map(ret, 'g:WebDevIconsGetFileTypeSymbol(v:val) .. " " .. v:val')
         hl_list = reduce(hl_list, (a, v) => {
            v[1] += matched_hl_offset
            return add(a, v)
         }, [])
    endif

    popup.MenuSetText(menu_wid, ret)
    popup.MenuSetHl('select', menu_wid, hl_list)
    if enable_devicons
        devicons.AddColor(menu_wid)
    endif
enddef

def Cleanup()
    timer_stop(async_tid)
enddef

# This function spawn a popup picker for user to select an item from a list.
# params:
#   - list: list of string to be selected. can be empty at init state
#   - opts: dict of options
#       - comfirm_cb: callback to be called when user select an item.
#           comfirm_cb(menu_wid, result). result is a list like ['selected item']
#       - preview_cb: callback to be called when user move cursor on an item.
#           preview_cb(menu_wid, result). result is a list like ['selected item', opts]
#       - input_cb: callback to be called when user input something. If input_cb
#           is not set, then the input will be used as the pattern to filter the
#           list. If input_cb is set, then the input will be passed to given callback.
#           input_cb(menu_wid, result). the second argument result is a list ['input string', opts]
#       - preview: wheather to show preview window, default 1
#       - width: width of the popup window, default 80. If preview is enabled,
#           then width is the width of the total layout.
#       - xoffset: x offset of the popup window. The popup window is centered
#           by default.
#       - scrollbar: wheather to show scrollbar in the menu window.
#       - preview_ratio: ratio of the preview window. default 0.5
# return:
#   - a list [menu_wid, prompt_wid]
#   - if has preview = 1, then return [menu_wid, prompt_wid, preview_wid]
export def Start(li_raw: list<string>, opts: dict<any>): list<number>
    cwd = getcwd()
    prompt_str = ''

    enable_devicons = has_key(opts, 'enable_devicons') ? opts.enable_devicons : 0

    opts.move_cb = has_key(opts, 'preview_cb') ? opts.preview_cb : v:null
    opts.select_cb = has_key(opts, 'select_cb') ? opts.select_cb : v:null
    opts.input_cb = has_key(opts, 'input_cb') ? opts.input_cb : function('Input')
    opts.dropdown = enable_dropdown

    var ret = popup.PopupSelection(opts)
    const win_types = ['menu', 'prompt', 'preview', 'info']
    for i in range(len(ret))
        windows[win_types[i]] = ret[i]
    endfor
    menu_wid = ret[0]
    fzf_list = li_raw
    var li = copy(li_raw)
    if enable_devicons
         map(li, 'g:WebDevIconsGetFileTypeSymbol(v:val) .. " " .. v:val')
    endif
    popup.MenuSetText(menu_wid, li)
    if enable_devicons
        devicons.AddColor(menu_wid)
    endif

    autocmd User PopupClosed ++once Cleanup()
    return ret
enddef
