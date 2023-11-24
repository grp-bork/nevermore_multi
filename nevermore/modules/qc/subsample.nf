process calculate_library_size_cutoff {
	input:
	path(readcounts)
	val(percentile)
	
	output:
	path("library_sizes.txt"), emit: library_sizes

	script:
	"""
	#!/usr/bin/env python
	
	import glob
	import statistics

	"A_Niclo_T3h_r2.metaT.singles.raw.txt"
	d = dict(
		sorted(
			((f[:-8], int(open(f, "rt").read().strip().split("\t")[-1]))
			for f in glob.glob("*.raw.txt")),
			key=lambda x:x[1]
		)
	)
	percentile = ${percentile}
	percentiles = statistics.quantiles(d.values(), n=100)
	mean_low_counts = statistics.mean(v for v in d.values() if v < percentiles[percentile - 1])

	with open('library_sizes.txt', 'wt') as _out:
		print(*('sample', 'size', 'do_subsample', 'target_size'), sep='\\t', file=_out)
		for k, v in d.items():
			print(k, v, int(v < percentiles[percentile - 1]), int(mean_low_counts + 0.5), sep='\\t', file=_out)

	print(mean_low_counts)

	"""
	// nlibs=\$(cat ${readcounts} | wc -l)
	// cat ${readcounts} | sort -k1,1g | awk -v nlibs=\$nlibs 'BEGIN {q75=int(nlibs*0.75 + 0.5)} NR<q75 {print;}' | awk '{sum+=\$1} END {printf("%d\\n", sum/NR) }'
	// cat ${readcounts} | sort -k1,1g | awk -v nlibs=\$nlibs 'BEGIN {q75=int(nlibs*0.75 + 0.5)} NR<q75 {sum+=$1; n+=1;} END {printf("%d\n",sum/n) }'


}