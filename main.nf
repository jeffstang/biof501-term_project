/*
 * RNASeq Differential Analysis Pipeline
 * This is a pipeline designed for analyzing transcriptomics data in the context of cytokines. 
 * A fast approach of analyzing large RNAseq datasets starting from raw paired-end reads 
 * I prioritize computational efficiency using an alignment-free method to generate a report on cytokine perturbations.
 * 
 * Author: Jeffrey Tang
 *
 */

/*
  * Include the following modules:
*/
/// include { FASTQC }              from "./modules/local/fastqc"
/// include { MULTIQC }             from "./modules/local/multiqc"
/// include { TRIM_READS }          from "./modules/local/trimmomatic"
/// include { SALMON_QUANT }        from "./modules/local/salmon"

/*
 * Loading default parameters
*/

params.fastq = "$baseDir/data/raw/*{1,2}*.fastq.gz"
params.fasta = "$baseDir/data/reference/grcm39_transcript_transcript.fa.gz"
params.gtf = "$baseDir/data/reference/grcm39_transcript_transcript.gtf.gz"
params.outdir = "results"

log.info """\
        RNASeq Differential Analysis Pipeline
        =====================================
        FASTQ                    : ${params.fastq}
        Transcriptome FASTA      : ${params.fasta}
        Gene Annotations         : ${params.gtf}
        Results Directory        : ${params.outdir}
        """
        .stripIndent()

fasta = file(params.fasta)
gtf = file(params.gtf)

fasta_url = "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M36/gencode.vM36.transcripts.fa.gz"
gtf_url = "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M36/gencode.vM36.basic.annotation.gtf.gz"

//
// WORKFLOW: run main analysis pipeline
//

workflow {
    // Check if reference files (FASTA and GTF exist), download if necessary:
    DOWNLOAD_REFERENCES(fasta_url, gtf_url)
    
    // Initialize the read pair channel
    Channel
        .fromFilePairs( params.fastq, checkIfExists: true )
        .ifEmpty { error "Cannot find matching FASTQ files: ${params.fastq}" }
        .set { read_pairs_ch } 
         
    // Generate FASTQC reports on raw reads
    FASTQC( read_pairs_ch, "raw" )
 
    // Use trimmomatic to trim reads to remove low quality reads and adapter sequences
    TRIM_READS( read_pairs_ch )

    // Generate FASTQC reports on trimmed reads
    FASTQC(TRIM_READS.out.trimmed_reads, "trimmed")
    
    // Run Salmon processes
    RUN_SALMON()
}

/* 
 * Subworkflows:
 * Download FASTA and GTF files
*/
workflow DOWNLOAD_REFERENCES {
    take:
    fasta_url
    gtf_url
    
    main:
    // Retrieve transcript fasta
    DOWNLOAD_FASTA(fasta_url)

    // Retrieve transcript annotations file
    DOWNLOAD_GTF(gtf_url)
}

/* Run Salmon tool
*/ 
workflow RUN_SALMON {
    take:
    transcriptome_fasta
    gtf
    trimmed_fastq
    index
    

    // Index the reference transcriptome
    SALMON_INDEX(transcriptome_fasta)

    SALMON_QUANT(index, gtf, trimmed_fastq)
}

// Processes
process DOWNLOAD_FASTA {
    errorStrategy 'retry' 
    maxRetries 2
    cache 'deep'
    
    input:
    val(fasta_url)

    output: 
    path("*.fa.gz"), emit: fasta
                
    script:
    """
    wget -O ${fasta_url.split("/")[-1]} ${fasta_url}
    """    
}

process DOWNLOAD_GTF {
    errorStrategy 'retry'
    maxRetries 2
    cache 'deep'

    input:
    val(gtf_url)

    output: 
    path("*.gtf.gz"), emit: annotation

    script:
    """
    wget -O ${gtf_url.split("/")[-1]} ${gtf_url}
    """
}

process FASTQC {    
    tag "FASTQC on ${read_type} reads for sample ${sample_id}"
    publishDir "${params.outdir}/fastqc/${read_type}/${sample_id}", mode: 'copy'
    
    input:
    tuple val(sample_id), path(reads)    
    val(read_type)
    
    output:
    path("*_fastqc.{zip,html}"), emit: fastqc_reports

    script:
    """
    fastqc -f fastq -q ${reads} 
    """
}

process TRIM_READS {
    tag "TRIM_READS on ${sample_id}"
    publishDir "${params.outdir}/trimmomatic", mode: 'copy'
    
    input: 
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("${sample_id}_R{1,2}.trimmed.fastq.gz"), emit: trimmed_paired
    tuple val(sample_id), path("${sample_id}_R{1,2}.unpaired.fastq.gz"), emit: trimmed_unpaired
    
    script:
    def (r1, r2) = reads
    """
    trimmomatic PE -threads 4 \
        $r1 $r2 \
        ${sample_id}_R1.trimmed.fastq.gz \
        ${sample_id}_R1.unpaired.fastq.gz \
        ${sample_id}_R2.trimmed.fastq.gz \
        ${sample_id}_R2.unpaired.fastq.gz \
        LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36
    """
}

process SALMON_INDEX {
    tag: "Creating Salmon index from ${transcriptome_fasta.name}"
    input:
    path(transcriptome_fasta)
    
    output:
    path("salmon_index"), emit: index

    script:
    """
    salmon index --threads 4 -t $transcriptomic_fasta -i index_ch
    """
}

process SALMON_QUANT {
    tag "Converting counts from ${sample_id}"
    publishDir "${params.outdir}/salmon_quant", mode: 'copy'

    input:
    path("index")
    path("gtf") 
    tuple val(sample_id), path(trimmed_R1), path(trimmed_R2)

    output:
    path(sample_id), emit: quant

    script:
    """
    salmon quant \
    --threads 4 --libType A \
    --index index \
    --validateMappings \
    --geneMap gtf \
    --output ${sample_id} \
    -1 ${trimmed_R1} \
    -2 ${trimmed_R2}
    """
}