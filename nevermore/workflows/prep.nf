#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { qc_bbduk } from "../modules/qc/bbduk"
include { qc_bbduk_stepwise_amplicon } from "../modules/qc/bbduk_amplicon"
include { qc_bbmerge } from "../modules/qc/bbmerge"
include { fastqc } from "../modules/qc/fastqc"
include { multiqc } from "../modules/qc/multiqc"
include { calculate_library_size_cutoff } from "../modules/qc/subsample"


def merge_pairs = (params.merge_pairs || false)
def keep_orphans = (params.keep_orphans || false)

def asset_dir = "${projectDir}/nevermore/assets"

print asset_dir

process concat_singles {
    input:
    tuple val(sample), path(reads)

    output:
    tuple val(sample), path("${sample}/${sample}.singles_R1.fastq.gz"), emit: reads

    script:
    """
    mkdir -p $sample
    cat ${reads} > ${sample}/${sample}.singles_R1.fastq.gz
    """
}


workflow nevermore_simple_preprocessing {

	take:

		fastq_ch

	main:
		rawcounts_ch = Channel.empty()
		if (params.run_qa || params.subsample) {

			fastqc(fastq_ch, "raw")
			rawcounts_ch = fastqc.out.counts

			if (params.run_qa) {
				multiqc(
					fastqc.out.stats.map { sample, report -> report }.collect(),
					"${asset_dir}/multiqc.config",
					"raw"
				)
			}

			if (params.subsample.subset) {
				
				fastq_ch
					.branch {
						subsample: params.subsample.subset == "all" || it[0].library_source == params.subsample.subset
						no_subsample: true
					}
					.set { check_subsample_ch }
				// subsample_ch = fastq_ch
				// 	.filter { params.subsample.subset == "all" || it[0].library_source == params.subsample.subset }
				// subsample_ch.dump(pretty: true, tag: "subsample_ch")

				calculate_library_size_cutoff(
					fastqc.out.counts
						.filter { params.subsample.subset == "all" || it[0].library_source == params.subsample.subset }
						.map { sample, counts -> return counts }
						.collect(),
					params.subsample.percentile
				)
				calculate_library_size_cutoff.out.library_sizes.view()

				check_subsample_ch
					.map { sample, fastqs -> return tuple(sample.id, sample, fastqs) }
					.join(
						
						calculate_library_size_cutoff.out.library_sizes
							.splitCsv(header: true, sep: '\t', strip: true)
							.map { row ->
								return tuple(row.sample, row.do_subsample, row.target_size)
							},
							by: 0,
							remainder: true						
					)
					.branch {
						subsample: it[3] == 1
						no_subsample: true
					}
					.set { subsample_ch }
				
				subsample_ch.subsample.dump(pretty: true, tag: "subsample_ch")
					

				
				


			}




		}

		processed_reads_ch = Channel.empty()
		orphans_ch = Channel.empty()

		if (params.amplicon_seq) {

			qc_bbduk_stepwise_amplicon(fastq_ch, "${asset_dir}/adapters.fa")
			processed_reads_ch = processed_reads_ch.concat(qc_bbduk_stepwise_amplicon.out.reads)
			orphans_ch = orphans_ch.concat(qc_bbduk_stepwise_amplicon.out.orphans)

		} else {

			qc_bbduk(fastq_ch, "${asset_dir}/adapters.fa")
			processed_reads_ch = processed_reads_ch.concat(qc_bbduk.out.reads)
			orphans_ch = qc_bbduk.out.orphans
				.map { sample, file -> 
					def meta = sample.clone()
					meta.id = sample.id + ".orphans"
					meta.is_paired = false
					return tuple(meta, file)
				}

		}

	emit:

		main_reads_out = processed_reads_ch
		orphan_reads_out = orphans_ch
		raw_counts = rawcounts_ch

}


workflow nevermore_preprocessing {

	take:
		fastq_ch

	main:

		qc_bbduk(fastq_ch)

		/* decide if we want to keep orphan reads generated by paired-end qc */

		orphan_reads_ch = qc_bbduk.out.orphans

		/* get the surviving paired-end reads from the qc */

		paired_reads_ch = qc_bbduk.out.reads
			.filter { it[1].size() == 2 }

		/* get the surviving single-end reads from the qc of single-end libraries (these are not orphans!) */

		singlelib_reads_ch = qc_bbduk.out.reads
			.filter { it[1].size() != 2 }

		/* merge_pairs implies that we want to keep the merged reads, which are 'longer single-ends' */

		if (merge_pairs) {

			/* attempt to merge the paired-end reads */

			qc_bbmerge(paired_reads_ch)

			/* join the orphans (potentially empty, s. a.) and the merged reads as all are single-end */

			if (keep_orphans) {
				single_reads_ch = orphan_reads_ch
					.join(qc_bbmerge.out.merged, remainder: true)
					.map { sample, orphans, merged ->
						return (orphans != null) ? tuple(sample, [orphans, merged]) : tuple(sample, merged)
					}

			} else {

				single_reads_ch = qc_bbmerge.out.merged

			}

			/* concatenate the joined single-end read files */

			concat_singles(single_reads_ch)

			/* join un-merged reads and single end reads into a common channel for downstream analysis */

			paired_out_ch = qc_bbmerge.out.pairs

			single_out_ch = singlelib_reads_ch
				.concat(concat_singles.out.reads)

		} else {

			/* join the paired-end, single-end (from se-libraries) and, if desired, the orphans into a common channel */

			paired_out_ch = paired_reads_ch

			concat_singles(orphan_reads_ch)

			single_out_ch = singlelib_reads_ch

			if (keep_orphans) {

				single_out_ch = single_out_ch
					.concat(concat_singles.out.reads)

			}

		}

	emit:
		paired_reads = paired_out_ch
		single_reads = single_out_ch
}
