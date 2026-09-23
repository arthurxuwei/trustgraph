# TrustGraph Librarian: Garage to Alibaba Cloud OSS

This migration changes only the Librarian blob store. Cassandra document metadata
and object IDs remain unchanged. Object keys stay in the `doc/<object-id>` layout.
Do not remove Garage until every source object has been verified in OSS and the
post-cutover observation period is complete.

## Target configuration

The production ECS and OSS bucket are both in `cn-shenzhen`. The dedicated
private bucket is `aml-trustgraph-library-1705398630702559`. The ECS instance
uses `TrustGraphOssRole`, whose custom policy is limited to this bucket and
its `doc/*` objects. No long-lived OSS AccessKey belongs in the launch YAML.

Configure the `trustgraph.librarian.Processor` parameters:

```yaml
object_store_provider: oss
object_store_endpoint: oss-cn-shenzhen-internal.aliyuncs.com
object_store_region: cn-shenzhen
object_store_use_ssl: true
object_store_bucket: aml-trustgraph-library-1705398630702559
object_store_role_name: TrustGraphOssRole
```

The `s3` provider remains the default for Garage and other S3-compatible
installations. OSS mode requires TLS, an explicit region and an ECS role;
it never creates a bucket or uses configured static access keys.

## Cutover and verification

1. Record Garage object count, total bytes and content hashes. Pre-copy to OSS
   while reads and writes continue; this is not yet a cutover.
2. In a maintenance window, stop new Librarian writes and wait for in-flight
   uploads and multipart sessions to complete. Run a final copy of changed or
   missing objects and compare the full `doc/*` inventory and content hashes.
3. Back up the live launch configuration. Deploy the patched 2.7.5 flow image
   to the control service only, set the configuration above, and restart that
   service. Do not upgrade unrelated TrustGraph services as part of this change.
4. Exercise a small upload, range read, full download, multipart upload and
   delete through the TrustGraph API. Verify the existing document library and
   monitor errors before reopening writes.
5. Retain the Garage volume and the original launch configuration. If a
   rollback is needed after OSS has accepted new writes, first stop writes and
   copy those new or changed objects back to Garage; simply switching the
   endpoint back would lose access to post-cutover data.

The S3-compatible MinIO client must use virtual-hosted-style OSS requests.
The production 2.7.5 image contains MinIO 7.2.20, which selects that style for
`aliyuncs.com` endpoints. Validate this, IAM permissions and multipart behavior
against the target bucket before changing production configuration.
