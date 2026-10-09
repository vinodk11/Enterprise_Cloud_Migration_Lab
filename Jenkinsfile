pipeline {
    agent any

    parameters {
        choice(name: 'ACTION', choices: ['plan', 'apply', 'destroy'], description: 'Terraform Action to perform')
        booleanParam(name: 'AUTO_APPROVE', defaultValue: true, description: 'Automatically approve apply without manual pause')
    }

    environment {
        TF_DIR = 'stage-1/terraform'
    }

    stages {
        stage('Checkout Code') {
            steps {
                checkout scm
            }
        }

        stage('Terraform Init & Validate') {
            steps {
                dir("${env.TF_DIR}") {
                    echo "Initializing Terraform with Azure Remote State..."
                    sh 'terraform init'
                    echo "Validating Terraform code..."
                    sh 'terraform fmt -check || true'
                    sh 'terraform validate'
                }
            }
        }

        stage('Terraform Plan') {
            steps {
                dir("${env.TF_DIR}") {
                    echo "Generating Terraform Execution Plan..."
                    sh 'terraform plan -input=false -out=tfplan'
                }
            }
        }

        stage('Manual Approval') {
            when {
                allOf {
                    expression { return params.ACTION == 'apply' }
                    expression { return !params.AUTO_APPROVE }
                }
            }
            steps {
                input message: 'Do you want to apply this Terraform plan to Azure?', ok: 'Deploy'
            }
        }

        stage('Terraform Execution') {
            steps {
                dir("${env.TF_DIR}") {
                    script {
                        if (params.ACTION == 'apply') {
                            echo "Applying Terraform configuration to Azure..."
                            sh 'terraform apply -input=false tfplan'
                        } else if (params.ACTION == 'destroy') {
                            echo "Destroying Terraform resources in Azure..."
                            sh 'terraform destroy -auto-approve -input=false'
                        } else {
                            echo "Plan only completed. Skipping apply."
                        }
                    }
                }
            }
        }

        stage('Show Outputs') {
            when {
                expression { return params.ACTION == 'apply' }
            }
            steps {
                dir("${env.TF_DIR}") {
                    sh 'terraform output'
                }
            }
        }
    }

    post {
        success {
            echo "Stage 1.1 Pipeline executed successfully!"
        }
        failure {
            echo "Pipeline failed. Review the logs above."
        }
    }
}
