// vim: set filetype=groovy:

def jobName = 'zeebe-DISTRO-maven-deploy'
def repository = 'zeebe'
def gitBranch = 'master'

def pom = 'pom.xml'
def mvnGoals = 'clean license:check source:jar javadoc:javadoc deploy -B'

def mavenVersion = 'maven-3.3-latest'
def mavenSettingsId = 'camunda-maven-settings'

def downstreamProjects = [
    'zeebe-QA-performance-tests-trigger',
]

def mavenGpgKeys = '''\
 #!/bin/bash

 if [ -e "${MVN_CENTRAL_GPG_KEY_SEC}" ]
 then
   gpg -q --allow-secret-key-import --import ${MVN_CENTRAL_GPG_KEY_SEC} || echo 'Private GPG Sign Key is already imported!.'
   rm ${MVN_CENTRAL_GPG_KEY_SEC}
 else
   echo 'Private GPG Key not found.'
 fi

 if [ -e "${MVN_CENTRAL_GPG_KEY_PUB}" ]
 then
   gpg -q --import ${MVN_CENTRAL_GPG_KEY_PUB} || echo 'Public GPG Sign Key is already imported!.'
   rm ${MVN_CENTRAL_GPG_KEY_PUB}
 else
   echo 'Public GPG Key not found.'
 fi
 '''

// script to set access rights on ssh keys
// and configure git user name and email
def setupGitConfig =
'''\
#!/bin/bash -xe

chmod 600 ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa.pub

git config --global user.email "ci@camunda.com"
git config --global user.name "camunda-jenkins"
'''

def dockerHubUpload =
'''\
#!/bin/bash -xe
echo "Building Zeebe Docker image."
docker build -t camunda/zeebe:${RELEASE_VERSION} --build-arg DISTBALL=./dist/target/zeebe-distribution-${RELEASE_VERSION}.tar.gz .

echo "Authenticating with DockerHub and pushing image."
docker login --username ${DOCKER_HUB_USERNAME} --pasword ${DOCKER_HUB_PASSWORD}

docker push camunda/zeebe:${RELEASE_VERSION}

docker tag camunda/zeebe:${RELEASE_VERSION} camunda/zeebe:latest
docker push camunda/zeebe:latest
'''

// properties used by the release build
def releaseProperties =
[
    resume: 'false',
    tag: '${RELEASE_VERSION}',
    releaseVersion: '${RELEASE_VERSION}',
    developmentVersion: '${DEVELOPMENT_VERSION}',
    arguments: '--settings=${NEXUS_SETTINGS} -DskipTests=true -Dgpg.passphrase="${GPG_PASSPHRASE}" -Dskip.central.release=${SKIP_DEPLOY_TO_MAVEN_CENTRAL} -Dskip.camunda.release=${SKIP_DEPLOY_TO_CAMUNDA_NEXUS}'
]


mavenJob(jobName)
{
    scm
    {
        git
        {
            remote
            {
                github 'zeebe-io/' + repository, 'ssh'
                credentials 'camunda-jenkins-github-ssh'
            }
            branch gitBranch
            extensions
            {
                localBranch gitBranch
                pathRestriction {
                    includedRegions ''
                    excludedRegions 'docs/.*\n\\.ci/.*'
                }
            }
        }
    }
    triggers
    {
        githubPush()
    }
    label 'dind'
    jdk 'jdk-8-latest'

    rootPOM pom
    goals mvnGoals
    localRepository LocalRepositoryLocation.LOCAL_TO_WORKSPACE
    providedSettings mavenSettingsId
    mavenInstallation mavenVersion

    wrappers
    {
        timestamps()

        timeout
        {
            absolute 60
        }

        configFiles
        {
            // jenkins github public ssh key needed to push to github
            custom('Jenkins CI GitHub SSH Public Key')
            {
                targetLocation '/home/camunda/.ssh/id_rsa.pub'
            }
            mavenSettings(mavenSettingsId) {
              variable('NEXUS_SETTINGS')
            }
            // jenkins github private ssh key needed to push to github
            custom('Jenkins CI GitHub SSH Private Key')
            {
                targetLocation '/home/camunda/.ssh/id_rsa'
            }
        }

        credentialsBinding {
          // maven central signing credentials
          string('GPG_PASSPHRASE', 'password_maven_central_gpg_signing_key')
          file('MVN_CENTRAL_GPG_KEY_SEC', 'maven_central_gpg_signing_key')
          file('MVN_CENTRAL_GPG_KEY_PUB', 'maven_central_gpg_signing_key_pub')
          usernamePassword('DOCKER_HUB_USERNAME', 'DOCKER_HUB_PASSWORD', 'camundajenkins-dockerhub')
        }

        release
        {
            doNotKeepLog false
            overrideBuildParameters true

            parameters
            {
                stringParam('RELEASE_VERSION', '0.1.0', 'Version to release')
                stringParam('DEVELOPMENT_VERSION', '0.2.0-SNAPSHOT', 'Next development version')
                booleanParam('SKIP_DEPLOY_TO_MAVEN_CENTRAL', false, 'If <strong>TRUE</strong>, skip the deployment to maven central. Should be used when testing the release.')
                booleanParam('SKIP_DEPLOY_TO_CAMUNDA_NEXUS', false, 'If <strong>TRUE</strong>, skip the deployment to camunda nexus. Should be used when testing the release.')
            }

            preBuildSteps
            {
                // setup git configuration to push to github
                shell setupGitConfig
                shell mavenGpgKeys

                // execute maven release
                maven
                {
                    mavenInstallation mavenVersion
                    providedSettings mavenSettingsId
                    goals 'release:prepare release:perform -Dgpg.passphrase="${GPG_PASSPHRASE}" -B'

                    properties releaseProperties
                    localRepository LocalRepositoryLocation.LOCAL_TO_WORKSPACE
                }

                //shell dockerHubUpload
            }

        }

    }

    publishers
    {

        deployArtifacts
        {
            repositoryId 'central'
            repositoryUrl 'https://oss.sonatype.org/content/repositories/snapshots'
            uniqueVersion true
            evenIfUnstable false
        }

        archiveJunit('**/target/surefire-reports/*.xml')
        {
            retainLongStdout()
        }

        extendedEmail
        {
          triggers
          {
              firstFailure
              {
                  sendTo
                  {
                      culprits()
                  }
              }
              fixed
              {
                  sendTo
                  {
                      culprits()
                  }
              }
          }
        }

        downstream(downstreamProjects.join(','), 'SUCCESS')
    }

    blockOnUpstreamProjects()
    logRotator(-1, 5, -1, 1)

}
