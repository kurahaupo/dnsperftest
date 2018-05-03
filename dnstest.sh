#!/usr/bin/env bash
# On first run, replace #! line with the appropriate local alternative.
f=$0
[[ $f = */* ]] || f=$( command -v "$f" )
[[ $f = /* ]] || f=$PWD/$f
if [[ -f "$f" ]] &&
    read g < "$f" &&
    [[ $g = '#!'*env*bash ]]
then
    h=${f##*/} h=${h%.*}
    for g in "/usr/local/bin/$h" "$HOME/bin/$h" "$f" ; do
        t=$g
        if [[ -d ${g%/*} && -w ${g%/*} ]]; then
            while [[ -z $t || $t -ef $f ]]; do
                t=$( tempfile ) || t="$f.~$RANDOM~$$~"
            done
            {
              printf '#!%s\n# (extracted from %s)\n' "$BASH" "$f" &&
              tail -n+32
            } < "$f" > "$t" &&
            chmod 755 "$t" &&
            { [[ $t -ef $g ]] ||
              mv -vfb "$t" "$g"
            } &&
            printf >&2 '\e[33;41mExtracted %s, running %s\e[39;49m\n\n' "$f" "$g $*" &&
            exec "$g" "$@"
        fi
    done
    printf >&2 '\e[33;41mFailed to extract %s, flow through\e[39;49m\n\n' "$f"
    unset f h g t
fi

if command -v drill > /dev/null ; then
    delve() {
        drill "$@"
    }
elif command -v dig > /dev/null ; then
    delve() {
        dig "$@"
    }
else
    printf >&2 "Neither dig nor drill was not found. Please install dnsutils or ldnsutils."
    exit 1
fi

mapfile -t nameservers < <( sed '/^nameserver  */!d; s///; s/.*/&#&/' < /etc/resolv.conf )

providers=(
    1.1.1.1'#cloudflare'
    4.2.2.1'#level3'
    8.8.8.8'#google'
    9.9.9.9'#quad9'
    80.80.80.80'#freenom'
    208.67.222.123'#opendns'
    199.85.126.20'#norton'
    185.228.168.168'#cleanbrowsing'
    77.88.8.7'#yandex'
    176.103.130.132'#adguard'
    156.154.70.3'#neustar'
    8.26.56.26'#comodo'
    2001:4860:4860::8888'#google(v6)'
)

# Domains to test. Duplicated domains are ok
test_domains=(
        amazon.com
        facebook.com
        gmail.com
    www.google.com
    www.reddit.com
        twitter.com
        whatsapp.com
        wikipedia.org
    www.youtube.com
)

pp_label() {
    printf '%-18s' "$*"
}

pp() {
    printf ' %7.7s' "$@"
}

ppms() {
    # re-scale from µs to ms
    local x l
    for x do
        if (( x<100 )); then
            x=00$x
        fi
        l=${#x}
        printf ' %7.1f' "${x::l-3}.${x:l-3}"
    done
}
nl() {
    printf '\n'
}

pp_label
pp "${test_domains[@]#www.}" Pass Fail Min Median Max Mean StdDev
nl

declare -Ai p_pass p_fail p_sum p_sum2 p_min p_max

for p in "${nameservers[@]}" "${providers[@]}"; do
    pip=${p%%#*}
    pname=${p##*#}
    ftimes=()
    (( sum = sum2 = count = 0 ))
    unset min max

    pp_label "$pname"
    for d in "${test_domains[@]}"; do

        # Perform measurement!
        t=$(
            delve +tries=1 +time=2 +noall +stats @"$pip" "$d" |
                sed -n 's/^;; Query time: \([0-9.]*\) msec/\1/p'
        )

        if [[ -n "$t" ]]; then
            # re-scale from ms to µs, so that we can do everything in integer
            # arithmetic without undue loss of precision
            if [[ $t = *.* ]] ; then
                usec=${t#*.}000
                t=${t%%.*}${usec::3}
            else
                t+=000
                (( t == 0 && ( t+=500 ) ))  # minimum of 0.5 ms ??
            fi

            (( sum += t,
               sum2 += t**2,
               ++count ))
            p_sum[$d]+=t
            p_sum2[$d]+=t**2
            p_pass[$d]+=1

            if [[ ! -v min ]] || (( min > t )); then min=$t ; fi
            if [[ ! -v max ]] || (( max < t )); then max=$t ; fi
            if [[ ! -v 'p_min[$d]' ]] || (( p_min[$d] > t )); then p_min[$d]=$t ; fi
            if [[ ! -v 'p_max[$d]' ]] || (( p_max[$d] < t )); then p_max[$d]=$t ; fi

            # Insertion sort: insert $t into ftimes so that it's kept in order
            for (( k=l=0, r=${#ftimes[@]}; l<r;)) do
                (( k=(l+r)/2 ))
                (( t == ftimes[k] )) && break
                if (( t < ftimes[k] )); then
                    (( r = k ))
                else
                    (( l = ++k ))
                fi
            done
            ftimes=( "${ftimes[@]:0:k}" "$t" "${ftimes[@]:k}" )

            ppms "$t"
        else
            (( ++fail ))
            p_pass[$d]+=1

            pp '-  '
        fi

    done

    (( pass = count,
       fail = ${#test_domains[@]} - pass ))

    # Most values are meaningless if there are no samples
    if (( count == 0 )); then
        pp - "$fail" - - - - -
        nl
        continue
    fi

    # find median
    if (( count % 2 == 0 )) ; then
        # when count is even, take average of two middle samples
        (( median = (ftimes[count/2-1] + ftimes[count/2]) / 2 ))
    else
        (( median = ftimes[count/2] ))
    fi

    # compute mean
    (( mean = sum/count ))

    # sample variance is undefined for fewer than 2 samples
    stddev=
    if (( count > 1 )) ; then
        # compute sample variance
        (( variance = (sum2 - sum**2/count)/(count-1) ))
        if (( variance > 0 )); then
            # compute standard deviation using bisection method to find square
            # root of variance; iterate until no change
            for (( stddev = variance/2+1, prev = -1 ; stddev != prev && stddev != prev+1 ; prev = stddev, stddev += variance/stddev, stddev /= 2 )) do :; done
        fi
    fi

    declare -n ref

    # Use dash instead of 0 for some values
    for ref in pass fail ; do
        if (( ref )); then
            pp $ref
        else
            pp -
        fi
    done

    for ref in min median max mean stddev ; do
        if [[ $ref ]] ; then
            l=${#ref}
            ppms "$ref"
        else
            pp -
        fi
    done
    nl
done

nl
for rr in Pass Fail
do
    pp_label "    $rr"
    n=
    for d in "${test_domains[@]}"; do
        r=p_${rr,,}"[$d]"
        t=${!r}
        if [[ -n $t ]]; then
            pp "$t"
        else
            pp -
        fi
    done
    nl
done

for rr in Min Max
do
    pp_label "    $rr"
    n=
    for d in "${test_domains[@]}"; do
        r=p_${rr,,}"[$d]"
        if [[ -v $r ]]; then
            t=${!r}
            ppms "$t"
        else
            pp "($r)"
        fi
    done
    nl
done

pp_label '    Mean'
n=
for d in "${test_domains[@]}"; do
    sum=${p_sum[$d]}
    count=${p_pass[$d]}
    if (( count > 0 )); then
        (( t = sum / count ))
        ppms "$t"
    else
        pp '-  '
    fi
done
nl

pp_label '    StdDev'
n=
for d in "${test_domains[@]}"; do
    sum=${p_sum[$d]}
    sum2=${p_sum2[$d]}
    count=${p_pass[$d]}
    if (( count > 1 )); then

        # compute sample variance
        (( variance = (sum2 - sum**2/count)/(count-1) ))
        if (( variance > 0 )); then
            # compute standard deviation using bisection method to find square
            # root of variance; iterate until no change
            for (( stddev = variance/2+1, prev = -1 ; stddev != prev && stddev != prev+1 ; prev = stddev, stddev += variance/stddev, stddev /= 2 )) do :; done
        fi

        (( t = stddev ))
        ppms "$t"
    else
        pp '-  '
    fi
done
nl

exit 0
