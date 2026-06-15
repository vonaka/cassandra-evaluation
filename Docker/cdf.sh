#!/usr/bin/env bash

# Compute the latency distribution of each protocol (broken down per operation) over all the YCSB workloads.

DIR=$(dirname "${BASH_SOURCE[0]}")

source ${DIR}/utils.sh
source ${DIR}/run_benchmarks.sh

usage() {
    echo "Usage: $0 [--dry-run] [--test] [--protocols=LIST] [--nodes=N]"
    echo "  --dry-run        Skip the experiment run; only draw plots using existing data."
    echo "  --test           Use a 60s run time and right-size containers to fit this machine."
    echo "  --protocols=LIST Override the list of protocols to run (space-separated)."
    echo "  --nodes=N        Number of nodes (default: 5)."
}

dry_run=0
test_run=0
protocols_override=""
nodes_override=""
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            dry_run=1
            ;;
        --test)
            test_run=1
            ;;
        --protocols=*)
            protocols_override="${arg#*=}"
            ;;
        --nodes=*)
            nodes_override="${arg#*=}"
            ;;
        *)
            echo "Unknown parameter: $arg"
            usage
            exit 1
            ;;
    esac
done

mkdir -p ${LOGDIR}/cdf
mkdir -p ${RESULTSDIR}

workload_type="site.ycsb.workloads.CoreWorkload"
workloads="a"
protocols=$(awk -F',' 'NR>1 && $1!="" {print $1}' protocols.csv | grep -v cockroachdb-opt | grep -v cockroachdb-bad | grep -v accord-cmt | paste -sd' ')
if [ -n "$protocols_override" ]; then
    protocols="$protocols_override"
fi
nodes=${nodes_override:-5}
replication_factor=${nodes}
cities="Hanoi Lyon NewYork Rotterdam SaoPaulo" # can be ""
plot_average=true
records=$(config records)
threads=$(config threads)
ops_per_thread=0

if [ "$test_run" -eq 1 ]; then
    original_machine=$(config machine)
    original_maxexecutiontime=$(config maxexecutiontime)
    restore_test_settings() {
        sed -i "s/^machine=.*/machine=${original_machine}/" "${CONFIG_FILE}"
        sed -i "s/^maxexecutiontime=.*/maxexecutiontime=${original_maxexecutiontime}/" "${CONFIG_FILE}"
    }
    trap restore_test_settings EXIT
    compute_test_machine "${nodes}"
    sed -i "s/^maxexecutiontime=.*/maxexecutiontime=60/" "${CONFIG_FILE}"
fi
maxexecutiontime=$(config maxexecutiontime)

if [ "$dry_run" -eq 0 ]; then
    docker system prune -f --volumes
    pull_images
    do_clean_up=0
    for p in ${protocols}
    do
        # clean prior logs
        rm -f ${LOGDIR}/cdf/*${p}*
        
        do_create_and_load=1
        total=$(( $(echo ${workloads} | wc -w) * $(echo ${threads} | wc -w) ))
        count=0
        tracing="false"
        if printf '%s\n' "$p" | grep -wF -q -- "cockroachdb";
        then
	    tracing="false" # FIXME
        fi
        for w in ${workloads}
        do
	    for c in ${threads}
	    do
	        ts=$(date +%Y%m%d%H%M%S%N)
	        output_file="${LOGDIR}/cdf/${p}_${nodes}_${w}_${ts}.dat"
	        run_benchmark ${p} ${c} ${nodes} ${replication_factor} ${workload_type} ${w} ${records} $((threads * ops_per_thread)) ${output_file} ${do_create_and_load} 0 -p db.tracing=${tracing} -p maxexecutiontime=${maxexecutiontime} -p warmupexecutiontime=60
	        do_create_and_load=0
	        count=$((count+1))
	    done
        done

        log "Checking node health after benchmark for protocol '${p}'..."
        for i in $(seq 1 ${nodes}); do
            cname="$(config node_name)${i}"
            status=$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || echo "not found")
            if [ "${status}" = "running" ]; then
                proc=$(docker exec "${cname}" ps aux 2>/dev/null | grep -c "[Cc]assandra" || echo 0)
                log "  ${cname}: running (cassandra processes: ${proc})"
            else
                log "  ${cname}: ${status} -- UNEXPECTED"
            fi
        done

        stop_benchmark "${p}" "${nodes}"
    done
fi

debug "Parsing results..."
${DIR}/parse_ycsb_to_csv.sh ${LOGDIR}/cdf/* > ${RESULTSDIR}/cdf.csv

debug "Plotting..."
if [ "$plot_average" = true ]; then
    python3 ${DIR}/cdf.py ${RESULTSDIR}/cdf.csv ${workloads} ${nodes} ${cities} ${DIR}/latencies.csv ${RESULTSDIR}/cdf.tex --average
else
    python3 ${DIR}/cdf.py ${RESULTSDIR}/cdf.csv ${workloads} ${nodes} ${cities} ${DIR}/latencies.csv ${RESULTSDIR}/cdf.tex
fi

if command -v pdflatex >/dev/null 2>&1; then
    pdflatex -jobname=cdf -output-directory=${RESULTSDIR} \
    "\documentclass{article}\
     \usepackage{pgfplots}\
     \usepackage{tikz}\
     \usepackage{ifthen}\
     \usepackage{xspace}\
     \newcommand{\Accord}{\textsc{Entente}\xspace}\
     \usetikzlibrary{decorations.pathreplacing,positioning,automata,calc}\
     \usetikzlibrary{shapes,arrows}\
     \usepgflibrary{shapes.symbols}\
     \usetikzlibrary{shapes.symbols}\
     \usetikzlibrary{patterns}\
     \usetikzlibrary{matrix, positioning, pgfplots.groupplots}\
     \newboolean{details}\setboolean{details}{true}\
     \begin{document}\
     \thispagestyle{empty}\centering\input{cdf.tex}\
     \end{document}"  > /dev/null
else
    log "pdflatex not found, skipping PDF generation. Run locally with --dry-run to produce the PDF."
fi


