#!/bin/bash
set -euo pipefail
export LC_ALL=C
export COPYFILE_DISABLE=1

usage() {
    cat <<'USAGE'
Usage: run.sh <corpora-dir> [formats] [corpora] [--references] [--level N] [--threads N] [--progress] [--mode recursive|items|batch]
  formats: comma- or space-separated; default "zip tar tgz tbz txz 7z lha"
  corpora: comma- or space-separated; default "text random headers small"
  --references  Also measure zip -r -6, tar | xz -6 -T0, and 7zz a -mx6 when present
  --level N     Forward deflateLevel (0...9) to gyoshuku-bench only
  --threads N   Forward compressionThreads (1...64) to gyoshuku-bench only
  --progress    Observe byte progress in gyoshuku-bench only
  --mode MODE   recursive (default), items or batch; gyoshuku-bench only
USAGE
}

fail() { echo "$*" >&2; exit 1; }

positionals=()
writer_options=()
references=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --references) references=true; shift ;;
        --progress) writer_options+=("$1"); shift ;;
        --mode)
            [[ $# -ge 2 && ( $2 == recursive || $2 == items || $2 == batch ) ]] || fail '--mode requires recursive, items or batch'
            writer_options+=("$1" "$2"); shift 2 ;;
        --level)
            [[ $# -ge 2 && $2 =~ ^[0-9]$ ]] || fail '--level requires 0...9'
            writer_options+=("$1" "$2"); shift 2 ;;
        --threads)
            [[ $# -ge 2 && $2 =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]] || fail '--threads requires 1...64'
            writer_options+=("$1" "$2"); shift 2 ;;
        --*) fail "Unknown option: $1" ;;
        *) positionals+=("$1"); shift ;;
    esac
done
[[ ${#positionals[@]} -ge 1 && ${#positionals[@]} -le 3 ]] || { usage >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail 'run.sh requires macOS /usr/bin/time -l (RSS in bytes).'
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
corpora_dir=$(cd -- "${positionals[0]}" && pwd -P)
format_spec=${positionals[1]:-"zip tar tgz tbz txz 7z lha"}
corpus_spec=${positionals[2]:-"text random headers small"}
read -r -a formats <<< "${format_spec//,/ }"
read -r -a corpora <<< "${corpus_spec//,/ }"
[[ ${#formats[@]} -gt 0 && ${#corpora[@]} -gt 0 ]] || fail 'Select at least one format and corpus.'
for format in "${formats[@]}"; do
    case $format in zip|tar|tgz|tbz|txz|7z|lha) ;; *) fail "Unknown format: $format" ;; esac
done
for corpus in "${corpora[@]}"; do
    case $corpus in
        text) source_name=text256.txt ;;
        random) source_name=random256.bin ;;
        headers|small) source_name=$corpus ;;
        *) fail "Unknown corpus: $corpus" ;;
    esac
    if [[ ! -e $corpora_dir/$source_name && $corpus != headers ]]; then
        fail "Missing corpus: $corpora_dir/$source_name (run make-corpora.sh first)"
    fi
done

swift build -c release --package-path "$script_dir" >&2
bin_dir=$(swift build -c release --package-path "$script_dir" --show-bin-path)
benchmark=$bin_dir/gyoshuku-bench
[[ -x $benchmark ]] || fail "Executable not found: $benchmark"
mkdir -p "$script_dir/.build/results"
results=$(mktemp -d "$script_dir/.build/results/run.XXXXXX")
echo "Logs and results: $results (archives removed after measurement)" >&2
if [[ -f $corpora_dir/manifest.json ]]; then cp "$corpora_dir/manifest.json" "$results/corpora.json"; fi
zip_tool=''
xz_tool=''
sevenzip_tool=''
if $references; then
    zip_tool=$(command -v zip || true)
    xz_tool=$(command -v xz || true)
    sevenzip_tool=$(command -v 7zz || true)
    [[ -n $zip_tool ]] || echo 'Skipping reference zip: not found.' >&2
    [[ -n $xz_tool ]] || echo 'Skipping reference xz: not found.' >&2
    [[ -n $sevenzip_tool ]] || echo 'Skipping reference 7zz: not found.' >&2
fi

measure() {
    local tool=$1 format=$2 corpus=$3 output=$4 threads=$5
    shift 5
    local log_base="$results/$corpus-$format-$tool" bytes metrics
    printf '%q ' "$@" > "$log_base.command"
    printf '\n' >> "$log_base.command"
    if ! /usr/bin/time -l "$@" > "$log_base.stdout" 2> "$log_base.time"; then
        cat "$log_base.stdout" "$log_base.time" >&2
        fail "Measurement failed: $tool / $format / $corpus; logs: $results"
    fi
    bytes=$(/usr/bin/stat -f '%z' "$output")
    metrics=$(awk '
        $2 == "real" && $4 == "user" { wall = $1; user = $3; have_time = 1 }
        /maximum resident set size/ { rss = $1; have_rss = 1 }
        END {
            if (!have_time || !have_rss) exit 1
            printf "%.3f\t%.2f\t%.3f", wall, rss / 1048576, user
        }
    ' "$log_base.time") || fail "Cannot parse /usr/bin/time output: $log_base.time"
    if [[ $tool == gyoshuku-bench ]]; then
        threads=$(sed -n 's/.* threads=\([0-9][0-9]*\).*/\1/p' "$log_base.stdout")
        [[ -n $threads ]] || fail "Missing thread count: $log_base.stdout"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$format" "$corpus" "$threads" "$metrics" "$bytes" | tee -a "$results/results.tsv"
    rm -- "$output"
}

printf 'tool\tformat\tcorpus\tthreads\twall_s\tpeak_rss_mib\tuser_s\toutput_bytes\n' | tee "$results/results.tsv"
cd -- "$corpora_dir"
for corpus in "${corpora[@]}"; do
    case $corpus in
        text) source_name=text256.txt ;;
        random) source_name=random256.bin ;;
        headers|small) source_name=$corpus ;;
    esac
    if [[ ! -e $source_name ]]; then echo "Skipping $corpus: $corpora_dir/$source_name is missing." >&2; continue; fi
    for format in "${formats[@]}"; do
        output="$results/$corpus.$format"
        # macOS の Bash 3.2 で空配列と nounset を併用する。
        measure gyoshuku-bench "$format" "$corpus" "$output" auto \
            "$benchmark" "$format" "$output" "$source_name" ${writer_options[@]+"${writer_options[@]}"}
        if $references; then
            case $format in
                zip)
                    if [[ -n $zip_tool ]]; then
                        measure zip zip "$corpus" "$output" 1 "$zip_tool" -r -6 "$output" "$source_name"
                    fi ;;
                txz)
                    if [[ -n $xz_tool ]]; then
                        measure tar+xz txz "$corpus" "$output" auto /bin/bash -o pipefail -c \
                            '/usr/bin/tar -cf - "$2" | "$3" -6 -T0 > "$1"' \
                            _ "$output" "$source_name" "$xz_tool"
                    fi ;;
                7z)
                    if [[ -n $sevenzip_tool ]]; then
                        measure 7zz 7z "$corpus" "$output" auto "$sevenzip_tool" a -mx6 "$output" "$source_name"
                    fi ;;
            esac
        fi
    done
done
