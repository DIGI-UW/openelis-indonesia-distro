## OpenELIS Global2 Docker Compose Setup
Docker Compose setup for OpenELIS-Global2

You can find more information on how to set up OpenELIS at our [docs page](http://docs.openelis-global.org/)

[![Build Status](https://github.com/I-TECH-UW/OpenELIS-Global-2/actions/workflows/ci.yml/badge.svg)](https://github.com/I-TECH-UW/OpenELIS-Global-2/actions/workflows/ci.yml)

[![Publish Docker Image Status](https://github.com/I-TECH-UW/OpenELIS-Global-2/actions/workflows/publish-and-test.yml/badge.svg)](https://github.com/I-TECH-UW/OpenELIS-Global-2/actions/workflows/publish-and-test.yml)

[![Build Off Line Docker Images](https://github.com/I-TECH-UW/openelis-docker/actions/workflows/build-installer.yml/badge.svg)](https://github.com/I-TECH-UW/openelis-docker/actions/workflows/build-installer.yml)

## ONLINE INSTALLATION

## Updating the DB Passord (Optional)
1. Update the Enviroment vaiable `OE_DB_PASSWORD` in the [.env](./.env) file for the 'clinlims' user

1. Update the Enviroment vaiable `ADMIN_PASSWORD` in the [.env](./.env) file for the 'admin' user

### Running OpenELIS Global with docker-compose
    docker-compose up -d

#### The Instance can be accessed at 

| Instance  |     URL       | credentials (user: password)|
|---------- |:-------------:|------:                       |
| OpenELIS Frontend  |    https://localhost/  |  admin: adminADMIN!



       
    

