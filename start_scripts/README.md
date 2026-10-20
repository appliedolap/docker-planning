# LCM imports on first start

Put Lifecycle Management exports here, one folder each, as exported from Shared Services (each folder holds an `Import.xml`). On the container's first start, after EPM is up, `container/entrypoint.sh` imports every one with `Utility.sh`. The credentials in `Import.xml` are replaced with the container's admin user.

A Planning application import needs its data source to exist first; see "Creating the Vision sample application" in the top-level README.
