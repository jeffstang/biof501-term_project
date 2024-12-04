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
 * Loading default parameters
*/

params.fastq = "$baseDir/data/raw/*{1,2}.fastq.gz"
params.fasta = "$baseDir/data/reference/grcm39_transcript.fa.gz"
params.gtf = "$baseDir/data/reference/grcm39_transcript.gtf.gz"
params.metadata_csv = "$baseDir/data/reference/metadata.csv" 
params.db = "$baseDir/data/reference/cellchatv2_mouseLRI.rda"
params.outdir = "results"

log.info """\
        RNASeq Differential Analysis and 
        ===============================================
        FASTQ                    : ${params.fastq}
        Transcriptome FASTA      : ${params.fasta}
        Gene Annotations         : ${params.gtf}
        Cell Chat DB v2          : ${params.db}
        Sample Info Table        : ${params.metadata_csv}
        Results Directory        : ${params.outdir}
        """
        .stripIndent()

fasta_url = "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M36/gencode.vM36.pc_transcripts.fa.gz"
gtf_url = "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M36/gencode.vM36.basic.annotation.gtf.gz"

// import processes from modules required to run the pipeline
include { DOWNLOAD_FASTA; DOWNLOAD_GTF }            from "./modules/download_ref"
include { FASTQC as FASTQC_RAW }                    from "./modules/fastqc"
include { FASTQC as FASTQC_TRIMMED }                from "./modules/fastqc"
include { CREATE_TX2GENE }                          from "./modules/convert_tx2gene"
include { SALMON_INDEX; SALMON_QUANT }              from "./modules/salmon"
include { TXIMPORT_PROCESS }                        from "./modules/tximport"
include { LIMMA_VOOM_DEA }                          from "./modules/diff_exp_analysis"
include { ENHANCED_VOLCANO_PLOT }                   from "./modules/plot_enhancedVolcano"
include {  }

// WORKFLOW: run main analysis pipeline

workflow {
    // Check if reference files (FASTA and GTF exist), download if necessary:
    DOWNLOAD_REFERENCES(fasta_url, gtf_url)
    
    // Initialize the read pair channel
    Channel
        .fromFilePairs( params.fastq, checkIfExists: true )
        .ifEmpty { error "Cannot find matching FASTQ files: ${params.fastq}" }
        .set { read_pairs_ch } 
         
    // Generate FASTQC reports on raw reads
    FASTQC_RAW( read_pairs_ch, "raw" )
 
    // Use trimmomatic to trim reads to remove low quality reads and adapter sequences
    TRIM_READS( read_pairs_ch )

    // Generate FASTQC reports on trimmed reads
    FASTQC_TRIMMED(TRIM_READS.out.trimmed_paired, "trimmed")
        
    // Run Salmon processes
    // Index the fasta file
    SALMON_INDEX( DOWNLOAD_REFERENCES.out.fasta )
    
    // Run the main salmon command for quantifying transcripts 
    SALMON_QUANT( 
        SALMON_INDEX.out.idx, 
        DOWNLOAD_REFERENCES.out.annotation, 
        TRIM_READS.out.trimmed_paired
        )

    // Create a tx2gene file from annotations GTF 
    CREATE_TX2GENE(DOWNLOAD_REFERENCES.out.annotation)

    // Gather all salmon-processed samples and define necessary inputs
    quant_dirs = SALMON_QUANT.out.quant.collect()
    tx2gene_input = CREATE_TX2GENE.out.tx2gene
    
    // Use tximport to merge and convert transcript IDs to gene names
    // This will generate a gene by samples counts matrix
    TXIMPORT_PROCESS(
    quant_dirs,
    tx2gene_input,
    'salmon_counts'
    )

    // Run differential expression analysis using limma-voom from tximport_process
    // output, which is a single salmon counts matrix. 
    // The inputs for this process are the tximport object, the metadata, and the output prefix to name the CSV
    // The expected output is the top table of differentially expressed genes
    txi_input = TXIMPORT_PROCESS.out.txi_object
    
    LIMMA_VOOM_DEA( 
        txi_input,
        file(params.metadata_csv),
        "logFC_DEG"
    )

}

/* 
 * Subworkflows:
 * I grouped the processes for downloading FASTA and GTF files
 * into one and called on DOWNLOAD_REFERENCES in the main workflow
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

    emit:
    fasta = DOWNLOAD_FASTA.out.fasta
    annotation = DOWNLOAD_GTF.out.annotation
}