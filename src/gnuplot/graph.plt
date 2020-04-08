set title customtitle
set timefmt '%Y-%m-%d %H:%M:%S'
set xdata time
set format x '%Y-%m-%d'

set object 1 rect from graph 0,0 to graph 1,1 behind
set object 1 rect fc rgb '#23272A' fillstyle solid 1.0

set xlabel 'Date' tc rgb 'white'
set ylabel 'Balance' tc rgb 'white'
set border lc rgb 'white'
set key tc rgb 'white'
set title tc rgb 'white'
set linetype 1 lc rgb '#AAAAFF' lw 2
set linetype 2 lc rgb '#99AAB5' lw 1 dt '-'
set grid linestyle 2
set rmargin 7
set bmargin 4

set font 'Open Sans,10'
set output imagefilename
set terminal pngcairo background rgb '#2C2F33' size 1600,600

set datafile separator ","
plot '<cat' using 1:2 notitle with steps lc 1
