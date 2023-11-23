#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { nevermore_main } from "./nevermore/workflows/nevermore"
// include { gffquant_flow } from "./nevermore/workflows/gffquant"
// include { fastq_input } from "./nevermore/workflows/input"
include { metaT_input; metaG_input; assembly_prep } from "./multi/workflows/input"

// include { rnaspades; metaspades } from "./imp/modules/assemblers/spades"
// include { bwa_index } from "./imp/modules/alignment/indexing/bwa_index"
// include { extract_unmapped } from "./imp/modules/alignment/extract"

// include { metaT_assembly } from "./imp/workflows/meta_t"
// include { assembly_prep } from "./imp/workflows/input"
// include { hybrid_megahit } from "./imp/modules/assemblers/megahit"
// include { get_unmapped_reads } from "./imp/workflows/extract"
// include { concatenate_contigs; filter_fastq } from "./imp/modules/assemblers/functions"

include { unicycler } from "./multi/modules/assembler/unicycler"
include { prokka } from "./multi/modules/annotators/prokka"
include { carveme } from "./multi/modules/annotators/carveme"
include { memote } from "./multi/modules/reports/memote"

// if (params.input_dir && params.remote_input_dir) {
// 	log.info """
// 		Cannot process both --input_dir and --remote_input_dir. Please check input parameters.
// 	""".stripIndent()
// 	exit 1
// } else if (!params.input_dir && !params.remote_input_dir) {
// 	log.info """
// 		Neither --input_dir nor --remote_input_dir set.
// 	""".stripIndent()
// 	exit 1
// }

// each sample has at most 2 groups of files: [2 x PE, 1 x orphan], [1 x singles]


def input_dir = (params.input_dir) ? params.input_dir : params.remote_input_dir

params.remote_input_dir = false

params.assembler = "megahit"


workflow {

	nvm_input_ch = Channel.empty()
	metaT_ch = Channel.empty()
	if (params.metaT_input_dir) {
		metaT_input(
			Channel.fromPath(params.metaT_input_dir + "/*", type: "dir")
		)
		metaT_ch = metaT_input.out.reads
		nvm_input_ch = nvm_input_ch.concat(metaT_ch)
	}
	metaG_ch = Channel.empty()
	if (params.metaG_input_dir) {
		metaG_input(
			Channel.fromPath(params.metaG_input_dir + "/*", type: "dir")
		)
		metaG_ch = metaG_input.out.reads
		nvm_input_ch = nvm_input_ch.concat(metaG_ch)
	}

	nevermore_main(nvm_input_ch)


	empty_file = file("${launchDir}/NO_INPUT")
	empty_file.text = "NOTHING TO SEE HERE."
	print empty_file

	long_reads_ch = Channel.of(empty_file)

	assembly_prep(
		nevermore_main.out.fastqs
			.filter { it[0].library_source == "metaG" }
	)

	metaG_assembly_ch = assembly_prep.out.reads
		.map { sample, fastqs -> return tuple(sample.id, sample, fastqs) }
		.groupTuple(by: 0, size: 2, remainder: true)
		.map { sample_id, sample, short_reads -> 
			def new_sample = [:]
			new_sample.id = sample_id
			new_sample.library_source = "metaG"
			new_sample.library = sample[0].library
			return tuple(new_sample, [short_reads].flatten(), [empty_file])
		}


	metaG_assembly_ch.dump(pretty: true, tag: "metaG_hybrid_input")

	unicycler(metaG_assembly_ch)

	prokka(unicycler.out.assembly_fasta)

	carveme(
		prokka.out.proteins,
		(params.annotation.carveme.mediadb) ?: "${projectDir}/assets/carveme/media_db.tsv"
	)

	memote(carveme.out.model)

}



// 	metaT_assembly(
// 		nevermore_main.out.fastqs
// 			.filter { it[0].library_source == "metaT" }			
// 	)

// 	// collect metaG fastqs per sample
// 	

// 	// assign proper sample labels to metaT contigs
// 	metaT_contigs_ch = metaT_assembly.out.final_contigs
// 		.map { sample, contigs ->
// 			def meta = [:]
// 			meta.id = sample.id.replaceAll(/\.singles$/, "").replaceAll(/\.metaT/, "")
// 			return tuple(meta, contigs)
// 		}
// 	metaT_contigs_ch.dump(pretty: true, tag: "metaT_contigs_ch")

// 	// group metaT files by sample id
// 	hybrid_assembly_input_ch = metaT_assembly.out.reads
// 		.map { sample, fastqs ->
// 			def meta = [:]
// 			meta.id = sample.id.replaceAll(/\.singles$/, "").replaceAll(/\.metaT/, "")
// 			return tuple(meta, fastqs)
			
// 		}
// 	hybrid_assembly_input_ch.dump(pretty: true, tag: "metaT_hybrid_input")

// 	// combine the metaT and metaG reads
// 	hybrid_assembly_input_ch = hybrid_assembly_input_ch
// 		.concat(
// 			metaG_assembly_ch
// 				.map { sample, fastqs ->
// 					def meta = [:]
// 					meta.id = sample.id.replaceAll(/\.singles$/, "").replaceAll(/\.metaG/, "")
// 					return tuple(meta, fastqs)

// 				}			
// 		)
// 		.groupTuple()
// 		.map { sample, fastqs -> return tuple(sample, fastqs.flatten()) }

// 	hybrid_assembly_input_ch.dump(pretty: true, tag: "all_reads_hybrid_input")

// 	// add the metaT contigs to the metaG/T input reads
// 	hybrid_assembly_input_ch = hybrid_assembly_input_ch
// 		.concat(
// 			metaT_contigs_ch
// 		)
// 		.groupTuple()
// 		.map { sample, data -> return tuple(sample, data[0], data[1]) }

// 	hybrid_assembly_input_ch.dump(pretty: true, tag: "hybrid_assembly_input_ch")

// 	// perform initial hybrid assembly, label the resulting contigs as hybrid and build bwa index
// 	if (params.assembler == "spades") {
// 		metaspades(hybrid_assembly_input_ch, "initial")
// 		contigs_ch = metaspades.out.contigs		
// 	} else {
// 		hybrid_megahit(hybrid_assembly_input_ch, "initial")
// 		contigs_ch = hybrid_megahit.out.contigs
// 	}

// 	contigs_ch = contigs_ch.map {
// 		sample, fastqs -> 
// 		def new_sample = sample.clone()
// 		new_sample.library_source = "hybrid"
// 		return tuple(new_sample, fastqs)
// 	}

// 	bwa_index(contigs_ch, "initial")

// 	bwa_index.out.index.dump(pretty: true, tag: "bwa_index.out.index")

// 	nevermore_main.out.fastqs.dump(pretty: true, tag: "nevermore_main.out.fastqs")

// 	// add the bwa indices to the input reads
// 	combined_assembly_input_index_ch = hybrid_assembly_input_ch
// 		.map { sample, fastqs, contigs -> return tuple(sample.id, sample, fastqs) }
// 		.join(bwa_index.out.index, by: 0)
// 		.map { sample_id, sample, fastqs, libsrc, index -> return tuple(sample_id, sample, fastqs, index) }
// 	combined_assembly_input_index_ch.dump(pretty: true, tag: "combined_assembly_input_index_ch")


// 	metaT_paired_unmapped_ch = combined_assembly_input_index_ch
// 		.map { sample_id, sample, fastqs, index ->
// 			def new_sample = [:]
// 			new_sample.id = sample.id + ".metaT"
// 			new_sample.library_source = "metaT"
// 			new_sample.is_paired = true
// 			new_sample.index_id = sample_id
// 			def wanted_fastqs = fastqs
// 				.findAll({ filter_fastq(it, true, "metaT") })
// 			// wanted_fastqs.addAll(fastqs.findAll( { it.name.endsWith("_R1.fastq.gz") && !it.name.matches("(.*)(singles|orphans|chimeras)(.*)") && it.name.matches("(.*)metaT(.*)") } ))
// 			// wanted_fastqs.addAll(fastqs.findAll( { it.name.endsWith("_R2.fastq.gz") && it.name.matches("(.*)metaT(.*)") } ))
// 			return tuple(new_sample, wanted_fastqs, index)
// 		}
// 		.filter { it[1].size() > 0 }
// 	metaT_single_unmapped_ch = combined_assembly_input_index_ch
// 		.map { sample_id, sample, fastqs, index ->
// 			def new_sample = [:]
// 			new_sample.id = sample.id + ".metaT.singles"
// 			new_sample.library_source = "metaT"
// 			new_sample.is_paired = false
// 			new_sample.index_id = sample_id
// 			def wanted_fastqs = fastqs
// 				.findAll({ filter_fastq(it, false, "metaT") })
// 			// wanted_fastqs.addAll(fastqs.findAll( { it.name.matches("(.*)(singles|orphans|chimeras)(.*)") && it.name.matches("(.*)metaT(.*)") } ))
// 			return tuple(new_sample, wanted_fastqs, index)
// 		}
// 		.filter { it[1].size() > 0 }
// 	metaG_paired_unmapped_ch = combined_assembly_input_index_ch
// 		.map { sample_id, sample, fastqs, index ->
// 			def new_sample = [:]
// 			new_sample.id = sample.id + ".metaG"
// 			new_sample.library_source = "metaG"
// 			new_sample.is_paired = true
// 			new_sample.index_id = sample_id
// 			def wanted_fastqs = fastqs
// 				.findAll({ filter_fastq(it, true, "metaG") })
// 			// wanted_fastqs.addAll(fastqs.findAll( { it.name.endsWith("_R1.fastq.gz") && !it.name.matches("(.*)(singles|orphans|chimeras)(.*)") && it.name.matches("(.*)metaG(.*)") } ))
// 			// wanted_fastqs.addAll(fastqs.findAll( { it.name.endsWith("_R2.fastq.gz") && it.name.matches("(.*)metaG(.*)") } ))
// 			return tuple(new_sample, wanted_fastqs, index)
// 		}
// 		.filter { it[1].size() > 0 }
// 	metaG_single_unmapped_ch = combined_assembly_input_index_ch
// 		.map { sample_id, sample, fastqs, index ->
// 			def new_sample = [:]
// 			new_sample.id = sample.id + ".metaG.singles"
// 			new_sample.library_source = "metaG"
// 			new_sample.is_paired = false
// 			new_sample.index_id = sample_id
// 			def wanted_fastqs = fastqs
// 				.findAll({ filter_fastq(it, false, "metaG") })
// 			// wanted_fastqs.addAll(fastqs.findAll( { it.name.matches("(.*)(singles|orphans|chimeras)(.*)") && it.name.matches("(.*)metaG(.*)") } ))
// 			return tuple(new_sample, wanted_fastqs, index)
// 		}
// 		.filter { it[1].size() > 0 }

// 	extract_unmapped_ch = Channel.empty()
// 		.concat(metaT_paired_unmapped_ch)
// 		.concat(metaT_single_unmapped_ch)
// 		.concat(metaG_paired_unmapped_ch)
// 		.concat(metaG_single_unmapped_ch)
	
// 	extract_unmapped_ch.dump(pretty: true, tag: "extract_unmapped_ch")

// 	base_id_ch = nevermore_main.out.fastqs
// 		.map { sample, fastqs -> 
// 			def sample_base_id = sample.id.replaceAll(/.(orphans|singles|chimeras)$/, "").replaceAll(/.meta[GT]$/, "")
// 			return tuple(sample_base_id, sample, [fastqs].flatten())
// 		}
	
// 	base_id_ch.dump(pretty: true, tag: "base_id_ch")

// 	index_and_fastqs_ch = bwa_index.out.index.combine(base_id_ch, by: 0)
// 	index_and_fastqs_ch.dump(pretty: true, tag: "index_and_fastqs_ch")

// 	with_index_ch = base_id_ch.combine(bwa_index.out.index)
// 	with_index_ch.dump(pretty: true, tag: "with_index_ch")

// 	joined_ch = base_id_ch.join(bwa_index.out.index, by: 0)
// 	joined_ch.dump(pretty: true, tag: "joined_ch")

// 	// base_id_ch.combine(bwa_index.out.index, by: 0).dump(pretty: true, tag: "base_id_ch")

// 	// post_assembly_check_ch = nevermore_main.out.fastqs
// 	// 	.map { sample, fastqs -> 
// 	// 		sample_base_id = sample.id //
// 	// 		sample_base_id = sample_base_id.replaceAll(/.(orphans|singles|chimeras)$/, "").replaceAll(/.meta[GT]$/, "")
// 	// 		return tuple(sample_base_id, sample, [fastqs].flatten())
// 	// 	}
// 	// post_assembly_check_ch = with_index_ch
// 	// 	.map { sample_id, sample, fastqs, slib, index ->
// 	// 		sample.index_id = sample_id
// 	// 		return tuple(sample, fastqs, index) 
// 	// 	}

// 	// post_assembly_check_ch.dump(pretty: true, tag: "post_assembly_check_ch")
// 	extract_unmapped(extract_unmapped_ch, "initial")
// 	extract_unmapped.out.fastqs.dump(pretty: true, tag: "extract_unmapped_fastqs_ch")
	
// 	unmapped_ch = extract_unmapped.out.fastqs
// 		.map { sample, fastqs ->
// 			def new_sample = sample.clone()
// 			new_sample.id = sample.index_id
// 			return tuple(new_sample.id, new_sample, fastqs)
// 		}
// 		.groupTuple(by: 0, size: 2, remainder: true)
// 		.map { sample_id, sample, fastqs -> 
// 			def meta = [:]
// 			meta.id = sample_id
// 			return tuple(meta, fastqs.flatten())
// 		}

// 		.groupTuple(by: 0, size: 2, remainder: true) //, sort: true)
// 		.map { sample, fastqs ->
// 			def new_sample = sample.clone()
// 			new_sample.library_source = "hybrid"
// 			return tuple(new_sample, fastqs.flatten())
// 		}

// 	unmapped_ch.dump(pretty: true, tag: "unmapped_ch")
	
// 	if (params.assembler == "megahit") {
// 		megahit_hybrid_unmapped(unmapped_ch, Channel.of(empty_file))
// 		unmapped_contigs_ch = megahit_hybrid_unmapped.out.contigs
// 	}
// 	unmapped_contigs_ch.dump(pretty: true, tag: "unmapped_contigs_ch")

// 	all_contigs_ch = contigs_ch
// 		.concat(unmapped_contigs_ch)
// 		.groupTuple(by: 0, size: 2, remainder: true, sort: true)

// 	all_contigs_ch.dump(pretty: true, tag: "all_contigs_ch")
	
// 	concatenate_contigs(all_contigs_ch, "final", params.assembler)
// 	// hybrid_megahit(unmapped_ch.combine(Channel.of(empty_file)))
// 	// final_assembly_ch = get_unmapped_reads.out.reads
// 	// 	.map { sample, fastqs -> return tuple(sample, fastqs, [empty_file])}
// 	// final_assembly_ch.view()
	
// }

// workflow megahit_hybrid_unmapped {
// 	take:
// 		fastq_ch
// 		contigs_ch
// 	main:
// 		hybrid_megahit(fastq_ch.combine(contigs_ch), "final")
// 	emit:
// 		contigs = hybrid_megahit.out.contigs
// }