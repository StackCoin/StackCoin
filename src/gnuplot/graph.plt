set timefmt "%Y-%m-%d %H:%M:%S"
set xdata time
set format x "%Y-%m-%d"

set xlabel 'Date' tc rgb 'white'
set ylabel 'Balance' tc rgb 'white'
set border lc rgb 'white'
set key tc rgb 'white'
set linetype 1 lc rgb 'white' lw 2
set linetype 2 lc rgb 'white' lw 1 dt '-'
set grid linestyle 2
set rmargin 5

set font "Verdana,10"
set output imagefilename
set terminal pngcairo background rgb '#23272A' size 1600,600

set datafile separator ","
plot '<cat' using 1:2 notitle with steps lc 1
