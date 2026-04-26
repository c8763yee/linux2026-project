#!/usr/bin/env gnuplot

# Usage:
#   gnuplot -e "datafile='pid_data.csv'; outfile='pid_plot.png'" plot_pid.gp

if (!exists("datafile")) datafile = "pid_data.csv"
if (!exists("outfile"))  outfile  = "pid_plot.png"

set datafile separator ","
set term pngcairo size 1400,900 enhanced font "Noto Sans,12"
set output outfile

set multiplot layout 2,1 title "PID Controller Simulation" font ",16"

set grid
set key outside

stats datafile using (abs(column("setpoint"))) name "SP" nooutput
stats datafile using (abs(column("measurement"))) name "MEAS" nooutput
stats datafile using (abs(column("error"))) name "ERR" nooutput
y = (SP_max > MEAS_max) ? SP_max : MEAS_max
y = (ERR_max > y) ? ERR_max : y

# Clamp ylim to [-10n, 10n) where n = ceil(y / 10)
yr = (y > 0) ? ceil(y / 10.0) * 10 : 10
set yrange [-yr:yr]

set xlabel "Time (s)"
set ylabel "Output"
plot datafile using "t":"setpoint" with lines lw 2 lc rgb "#1f77b4" title "Setpoint", \
     datafile using "t":"measurement" with lines lw 2 lc rgb "#d62728" title "Measurement", \
     datafile using "t":"error" with lines dt 2 lw 1.5 lc rgb "#2ca02c" title "Error"

set xlabel "Time (s)"
set ylabel "Control / PID Terms"
set autoscale y
plot datafile using "t":"control" with lines lw 2 lc rgb "#9467bd" title "Control u", \
     datafile using "t":"p_term" with lines lw 1.5 lc rgb "#ff7f0e" title "P term", \
     datafile using "t":"i_term" with lines lw 1.5 lc rgb "#17becf" title "I term", \
     datafile using "t":"d_term" with lines lw 1.5 lc rgb "#8c564b" title "D term"

unset multiplot
unset output

print sprintf("Plot saved to %s (data: %s)", outfile, datafile)
