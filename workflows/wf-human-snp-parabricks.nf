
include {
    cat_haplotagged_contigs;
    getVersions;
    makeReport;
} from "../modules/local/wf-human-snp.nf"

include {
    haploblocks as haploblocks_snp;
    extract_not_haplotagged_contigs;
} from '../modules/local/common.nf'

// Parabricks DeepVariant processes
process pbrun_deepvariant {
    label "parabricks"
    cpus params.pbrun_threads ?: 32
    memory "64 GB"
    input:
        tuple path(bam), path(bai), val(meta)
        tuple path(ref), path(ref_idx), path(ref_cache), env(REF_PATH)
        path bed
    output:
        tuple val(meta), path("${meta.alias}.vcf.gz"), path("${meta.alias}.vcf.gz.tbi"), emit: vcf
        tuple val(meta), path("${meta.alias}.g.vcf.gz"), path("${meta.alias}.g.vcf.gz.tbi"), optional: true, emit: gvcf
    script:
        def bed_arg = bed.name != 'OPTIONAL_FILE' ? "--interval-file ${bed}" : ''
        def gvcf_arg = params.GVCF ? "--gvcf" : ""
        """
        pbrun deepvariant \\
            --ref ${ref} \\
            --in-bam ${bam} \\
            --out-variants ${meta.alias}.vcf.gz \\
            ${gvcf_arg} \\
            ${bed_arg} \\
            --num-threads ${task.cpus}
        """
}

process phase_deepvariant {
    label "wf_human_snp"
    cpus 4
    memory "8 GB"
    input:
        tuple val(meta), path(vcf), path(tbi)
        tuple path(bam), path(bai), val(bam_meta)
        tuple path(ref), path(ref_idx), path(ref_cache), env(REF_PATH)
    output:
        tuple val(meta), path("${meta.alias}.phased.vcf.gz"), path("${meta.alias}.phased.vcf.gz.tbi"), emit: phased_vcf
    script:
        """
        whatshap phase \\
            --reference ${ref} \\
            --output ${meta.alias}.phased.vcf.gz \\
            ${vcf} \\
            ${bam}
        tabix -p vcf ${meta.alias}.phased.vcf.gz
        """
}

process haplotag_bam {
    label "wf_human_snp"
    cpus 8
    memory "16 GB"
    input:
        tuple val(meta), path(vcf), path(tbi)
        tuple path(bam), path(bai), val(bam_meta)
        tuple path(ref), path(ref_idx), path(ref_cache), env(REF_PATH)
        each contig
    output:
        tuple val(meta), val(contig), path("${meta.alias}.${contig}.haplotagged.bam"), path("${meta.alias}.${contig}.haplotagged.bam.bai"), emit: phased_bam
    script:
        """
        whatshap haplotag \\
            --reference ${ref} \\
            --regions ${contig} \\
            --output ${meta.alias}.${contig}.haplotagged.bam \\
            ${vcf} \\
            ${bam}
        samtools index ${meta.alias}.${contig}.haplotagged.bam
        """
}

// Simplified workflow
workflow snp {
    take:
        bam_channel
        bed
        ref
        model  // Not used by DeepVariant, kept for compatibility
        genome_build
        extensions
        run_haplotagging
        using_user_bed
        chromosome_codes
    main:
        // Run Parabricks DeepVariant (single step variant calling)
        pbrun_deepvariant(bam_channel, ref, bed)

        contigs = Channel.from(chromosome_codes.findAll {
            it.startsWith("chr") && it != "chrM" && it != "chrMT"
        }.unique())

        if (run_haplotagging) {
            // Phase VCF
            phased_vcf = phase_deepvariant(
                pbrun_deepvariant.out.vcf,
                bam_channel,
                ref
            )

            // Haplotag BAM per contig
            haplotagged_ctg_bams = haplotag_bam(
                phased_vcf.phased_vcf,
                bam_channel,
                ref,
                contigs
            )

            // Extract non-haplotagged contigs
            haplotagged_fosn = haplotagged_ctg_bams
                .map { meta, contig, xam, xai -> contig }
                | collectFile(name: "haplotagged.fosn", newLine: true, sort: false)

            nothaplotagged_ctg_bams = extract_not_haplotagged_contigs(
                ref, bam_channel, haplotagged_fosn
            ) | transpose

            // Concatenate all BAMs
            xams_to_cat = haplotagged_ctg_bams
                .map { meta, contig, xam, xai -> [meta, xam] }
                | mix(nothaplotagged_ctg_bams)
                | groupTuple(by: 0)

            haplotagged_cat_xam = cat_haplotagged_contigs(xams_to_cat, ref, extensions)

            final_vcf = phased_vcf.phased_vcf
            hp_snp_blocks = haploblocks_snp(final_vcf, 'snp')
        } else {
            haplotagged_ctg_bams = Channel.empty()
            haplotagged_cat_xam = Channel.empty()
            final_vcf = pbrun_deepvariant.out.vcf
            hp_snp_blocks = Channel.empty()
        }

        // Handle gVCF
        if (params.GVCF) {
            final_gvcf = pbrun_deepvariant.out.gvcf.map { meta, gvcf, tbi -> [gvcf, tbi] }
        } else {
            final_gvcf = Channel.empty()
        }

        // Combine results
        deepvariant_results = haplotagged_cat_xam
            .concat(final_vcf.map { meta, vcf, tbi -> [vcf, tbi] })
            .concat(final_gvcf)
            .concat(hp_snp_blocks)

    emit:
        clair3_results = deepvariant_results  // Named for compatibility
        str_bams = haplotagged_ctg_bams.map { meta, sq, xam, xai -> tuple(xam, xai, meta + [sq:sq]) }
        vcf_files = final_vcf
        haplotagged_xam = haplotagged_cat_xam.combine(bam_channel.map { it[2] })
        contigs = contigs
}

// Reporting workflow
workflow report_snp {
    take:
        vcf_stats
        clinvar_vcf
        workflow_params

    main:
        software_versions = getVersions()
        makeReport(vcf_stats, software_versions.collect(), workflow_params, clinvar_vcf)

    emit:
        report = makeReport.out.report
        snp_stats_json = makeReport.out.json
}
