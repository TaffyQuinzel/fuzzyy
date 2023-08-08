vim9script

import autoload 'utils/selector.vim'
import autoload 'utils/devicons.vim'

const WIN_WIDTH = 0.8
var buf_dict: dict<any>
var devicon_char_width = devicons.GetDeviconCharWidth()

var enable_devicons = exists('g:fuzzyy_devicons') && exists('g:WebDevIconsGetFileTypeSymbol') ?
    g:fuzzyy_devicons : exists('g:WebDevIconsGetFileTypeSymbol')

def Preview(wid: number, opts: dict<any>)
    var result = opts.cursor_item
    if result == ''
        return
    endif
    var preview_wid = opts.win_opts.partids['preview']
    if enable_devicons
        # echom [result]
        result = strcharpart(result, devicon_char_width + 1)
    endif
    var file = buf_dict[result][0]
    var lnum = buf_dict[result][2]
    if !filereadable(file)
        if file == ''
            popup_settext(preview_wid, '')
        else
            popup_settext(preview_wid, file .. ' not found')
        endif
        return
    endif
    var bufnr = buf_dict[result][1]
    var ft = getbufvar(bufnr, '&filetype')
    var fileraw = readfile(file, '')
    var preview_bufnr = winbufnr(preview_wid)
    popup_settext(preview_wid, fileraw)
    try
        setbufvar(preview_bufnr, '&syntax', ft)
    catch
    endtry
    win_execute(preview_wid, 'norm! ' .. lnum .. 'G')
    win_execute(preview_wid, 'norm! zz')
enddef

def Select(wid: number, result: list<any>)
    var buf = result[0]
    echo buf
    if enable_devicons
        buf = strcharpart(buf, devicon_char_width + 1)
    endif
    var bufnr = buf_dict[buf][1]
    if bufnr != bufnr('$')
        var action = 'buffer '
        if len(result) > 1
            var key = result[1]
            if key == "\<CR>" # current window
                action = 'buffer '
            elseif key == "\<c-t>" # new tab
                action = 'tabnew | buffer '
            elseif key == "\<c-v>" # vertical split
                action = 'vsp | buffer '
            elseif key == "\<c-s>" # split
                action = 'sb '
            endif
        endif
        execute(action .. bufnr)
    endif
enddef

export def Start()
    var buf_data = getbufinfo({'buflisted': 1, 'bufloaded': 1})
    buf_dict = {}
    var bufs = reduce(buf_data, (acc, buf) => {
        var file = fnamemodify(buf.name, ":~:.")
        if len(file) > WIN_WIDTH / 2 * &columns
            file = pathshorten(file)
        endif
        acc[file] = [buf.name, buf.bufnr, buf.lnum]
        return acc
    }, buf_dict)
    var winds = selector.Start(keys(bufs), {
        preview_cb:  function('Preview'),
        select_cb:  function('Select'),
        width: WIN_WIDTH,
        dropdown: 0,
        preview:  1,
        scrollbar: 0,
        enable_devicons: enable_devicons,
    })
enddef
