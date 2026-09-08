" plugin/spark.vim -- the loader: one user command, nothing else. The key
" is the user's own mapping (README); the plugin binds none itself, and
" autoload/spark.vim loads only when first used.
if exists('g:loaded_spark')
    finish
endif
let g:loaded_spark = 1

if !has('job') || !has('channel') || !exists('*appendbufline')
    finish
endif

command! -nargs=* -range Spark call spark#command(<range>, <line1>, <line2>, <q-args>)
