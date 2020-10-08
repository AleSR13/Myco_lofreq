#!/bin/bash

#load in functions
set -o allexport
source bin/functions.sh
eval "$(parse_yaml config/pipeline_parameters.yaml "params_")"
eval "$(parse_yaml config/config.yaml "configuration_")"
set +o allexport

UNIQUE_ID=$(bin/generate_id.sh)
SET_HOSTNAME=$(bin/gethostname.sh)


### conda environment
PATH_MASTER_YAML="envs/master_env.yaml"
MASTER_NAME=$(head -n 1 ${PATH_MASTER_YAML} | cut -f2 -d ' ') # Extract Conda environment name as specified in yaml file

### Default values for CLI parameters
INPUT_DIR="raw_data/"
OUTPUT_DIR="out/"
SKIP_CONFIRMATION="FALSE"
SNAKEMAKE_UNLOCK="FALSE"
CLEAN="FALSE"
HELP="FALSE"
MAKE_SAMPLE_SHEET="FALSE"
SHEET_SUCCESS="FALSE"

### Parse the commandline arguments, if they are not part of the pipeline, they get send to Snakemake
POSITIONAL=()
while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -i|--input)
        INPUT_DIR="$2"
        shift # Next
        shift # Next
        ;;
        -o|--output)
        OUTPUT_DIR="$2"
        shift # Next
        shift # Next
        ;;
        -h|--help)
        HELP="TRUE"
        shift # Next
        ;;
        -sh|--snakemake-help)
        SNAKEMAKE_HELP="TRUE"
        shift # Next
        ;;
        --clean)
        CLEAN="TRUE"
        shift # Next
        ;;
        --make-sample-sheet)
        MAKE_SAMPLE_SHEET="TRUE"
        shift # Next
        ;;
        -y)
        SKIP_CONFIRMATION="TRUE"
        shift # Next
        ;;
        -u|--unlock)
        SNAKEMAKE_UNLOCK="TRUE"
        shift # Next
        ;;
        *) # Any other option
        POSITIONAL+=("$1") # save in array
        shift # Next
        ;;
    esac
done
set -- "${POSITIONAL[@]:-}" # Restores the positional arguments (i.e. without the case arguments above) which then can be called via `$@` or `$[0-9]` etc. These parameters are send to Snakemake.




### Print help message
if [ "${HELP:-}" == "TRUE" ]; then
    line
    cat <<HELP_USAGE
Myco_lofreq pipeline, version $VERSION, built with Snakemake
  Usage: bash $0 -i <INPUT_DIR> <parameters>
  N.B. it is designed for Illumina paired-end data only


Input:
  -i, --input [DIR]                 This is the folder containing your input fastq files.
                                    Default is raw_data/

  -o, --output [DIR]                This is the folder that will contain your results.
                                    Default is out/

Output (automatically generated):
  <output_dir>/                     Contains dir contains the results of every step of the pipeline.

  <output_dir>/log/                 Contains the log files for every step of the pipeline

  <output_dir>/log/drmaa	    Contains the .out and .err files of every job sent to the grid/cluster.

  <output_dir>/log/results	    Contains the log files and parameters that the pipeline used for the current run


Parameters:
  -h, --help                        Print the help document.

  -sh, --snakemake-help             Print the snakemake help document.

  --make-sample-sheet		    It creates a sample sheet but without actually running the pipeline.

  --clean (-y)                      Removes output (-y forces "Yes" on all prompts).
  
  -n, --dry-run                     Useful snakemake command that displays the steps to be performed without actually 
				    executing them. Useful to spot any potential issues while running the pipeline.

  -u, --unlock                      Unlocks the working directory. A directory is locked when a run ends abruptly and 
				    it prevents you from doing subsequent analyses on that directory until it gets unlocked.

  Other snakemake parameters	    Any other parameters will be passed to snakemake. Read snakemake help (-sh) to see
				    the options.


HELP_USAGE
    exit 0
fi





### Remove all output
###> Remove all output
if [ "${CLEAN:-}" == "TRUE" ]; then
    bash bin/Clean
    exit 0
fi



#### MAKE SURE CONDA WORKS ON ALL SYSTEMS
rcfile="${HOME}/.myco_lofreq_src"
conda_loc=$(which conda)


if [ ! -f "${rcfile}" ]; then
    if [ ! -z "${conda_loc}" ]; then

    #> I ripped this block from jovian
    #> Check https://github.com/DennisSchmitz/Jovian for the source code
    #> The specific file is bin/includes/Install_miniconda
    #> relevant lines are FROM line #51
    #>

    condadir="${conda_loc}"
    basedir=$(echo "${condadir}" | rev | cut -d'/' -f3- | rev)
    etcdir="${basedir}/etc/profile.d/conda.sh"
    bindir="${basedir}/bin"

    touch "${rcfile}"
    cat << EOF >> "${rcfile}"
if [ -f "${etcdir}" ]; then
    . "${etcdir}"
else
    export PATH="${bindir}:$PATH"
fi

export -f conda
export -f __conda_activate
export -f __conda_reactivate
export -f __conda_hashr
export -f __add_sys_prefix_to_path
EOF

    cat << EOF >> "${HOME}/.bashrc"
if [ -f "${rcfile}" ]; then
    . "${rcfile}"
fi
EOF

    fi 

fi



source "${HOME}"/.bashrc



###############################################################################################################
##### Installation block                                                                                  #####
###############################################################################################################

### Pre-flight check: Assess availability of required files, conda and master environment
if [ ! -e "${PATH_MASTER_YAML}" ]; then # If this yaml file does not exist, give error.
    line
    spacer
    echo -e "ERROR: Missing file \"${PATH_MASTER_YAML}\""
    exit 1
fi

if [[ $PATH != *${MASTER_NAME}* ]]; then # If the master environment is not in your path (i.e. it is not currently active), do...
    line
    spacer
    set +ue # Turn bash strict mode off because that breaks conda
    conda activate "${MASTER_NAME}" # Try to activate this env
    if [ ! $? -eq 0 ]; then # If exit statement is not 0, i.e. master conda env hasn't been installed yet, do...
        installer_intro
        if [ "${SKIP_CONFIRMATION}" = "TRUE" ]; then
            echo -e "\tInstalling master environment..." 
            conda env create -f ${PATH_MASTER_YAML} 
            conda activate "${MASTER_NAME}"
            echo -e "DONE"
        else
            while read -r -p "The master environment hasn't been installed yet, do you want to install this environment now? [y/N] " envanswer
            do
                envanswer=${envanswer,,}
                if [[ "${envanswer}" =~ ^(yes|y)$ ]]; then
                    echo -e "\tInstalling master environment..." 
                    conda env create -f ${PATH_MASTER_YAML}
                    conda activate "${MASTER_NAME}"
                    echo -e "DONE"
                    break
                elif [[ "${envanswer}" =~ ^(no|n)$ ]]; then
                    echo -e "The master environment is a requirement. Exiting because myco_lofreq cannot continue without this environment"
                    exit 1
                else
                    echo -e "Please answer with 'yes' or 'no'"
                fi
            done
        fi
    fi
    set -ue # Turn bash strict mode on again
    echo -e "Succesfully activated master environment"
fi


if [ "${SNAKEMAKE_UNLOCK}" == "TRUE" ]; then
    printf "\nUnlocking working directory...\n"
    snakemake -s Snakefile --profile config --unlock
    printf "\nDone.\n"
    exit 0
fi


### Print Snakemake help
if [ "${SNAKEMAKE_HELP:-}" == "TRUE" ]; then
    line
    snakemake --help
    exit 0
fi


### Pass other CLI arguments along to Snakemake
if [ ! -d "${INPUT_DIR}" ]; then
    minispacer
    echo -e "The input directory specified (${INPUT_DIR}) does not exist"
    echo -e "Please specify an existing input directory"
    minispacer
    exit 1
fi


### Generate sample sheet
if [  `ls -A "${INPUT_DIR}" | grep 'R[0-9]\{1\}.*\.f[ast]\{0,3\}q\.\?[gz]\{0,2\}$' | wc -l` -gt 0 ]; then
    minispacer
    echo -e "Files in input directory (${INPUT_DIR}) are present"
    echo -e "Generating sample sheet..."
    python bin/generate_sample_sheet.py "${INPUT_DIR}" > sample_sheet.yaml
    if [ $(wc -l sample_sheet.yaml | awk '{ print $1 }') -gt 2 ]; then
        SHEET_SUCCESS="TRUE"
    fi
else
    minispacer
    echo -e "The input directory you specified (${INPUT_DIR}) exists but is empty or does not contain the expected input files...\nPlease specify a directory with input-data."
    exit 0
fi

### Checker for succesfull creation of sample_sheet
if [ "${SHEET_SUCCESS}" == "TRUE" ]; then
    echo -e "Succesfully generated the sample sheet"
    echo -e "ready_for_start"
else
    echo -e "Couldn't find files in the input directory that ended up being in a .FASTQ, .FQ or .GZ format and that contain the letters 'R1' or 'R2' (for forward and reverse reads, respectively) on the name"
    echo -e "Please inspect the input directory (${INPUT_DIR}) and make sure the files are in one of the formats listed below"
    echo -e ".fastq.gz (Zipped Fastq)"
    echo -e ".fq.gz (Zipped Fq)"
    echo -e ".fastq (Unzipped Fastq)"
    echo -e ".fq (unzipped Fq)"
    exit 1
fi


if [ "${MAKE_SAMPLE_SHEET}" == "TRUE" ]; then
    echo -e "myco_lofreq_run:\n    identifier: ${UNIQUE_ID}" > config/variables.yaml
    echo -e "Server_host:\n    hostname: http://${SET_HOSTNAME}" >> config/variables.yaml
    echo -e "The sample sheet and variables file has now been created, you can now run the snakefile manually"
    exit 0
fi


### Actual snakemake command with checkers for required files. N.B. here the UNIQUE_ID and SET_HOSTNAME variables are set!
if [ -e sample_sheet.yaml ]; then
    echo -e "Starting snakemake"
    set +ue #turn off bash strict mode because snakemake and conda can't work with it properly
    echo -e "pipeline_run:\n    identifier: ${UNIQUE_ID}" > config/variables.yaml
    echo -e "Server_host:\n    hostname: http://${SET_HOSTNAME}" >> config/variables.yaml
    eval $(parse_yaml config/variables.yaml "config_")
    snakemake -s Snakefile --profile config --drmaa " -q bio -n {threads} -R \"span[hosts=1]\"" --drmaa-log-dir out/log/drmaa ${@}
    #echo -e "\nUnique identifier for this run is: $config_run_identifier "
    echo -e "bac gastro run complete"
    set -ue #turn bash strict mode back on
else
    echo -e "Sample_sheet.yaml could not be found"
    echo -e "This also means that the pipeline was unable to generate a new sample sheet for you"
    echo -e "Please inspect the input directory (${INPUT_DIR}) and make sure the right files are present"
    exit 1
fi

exit 0 
