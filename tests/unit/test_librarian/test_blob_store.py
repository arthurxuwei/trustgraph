import asyncio
import io
import pytest
from unittest.mock import MagicMock, patch, AsyncMock
from uuid import uuid4
from minio.error import S3Error
from trustgraph.librarian.blob_store import BlobStore, EcsRamRoleProvider
from trustgraph.librarian.librarian import Librarian

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_blob_store():
    """Create a BlobStore with mocked Minio client."""
    mock_minio = MagicMock()
    with patch('trustgraph.librarian.blob_store.Minio', return_value=mock_minio):
        # Prevent ensure_bucket from making network calls during init
        with patch('trustgraph.librarian.blob_store.BlobStore.ensure_bucket'):
            store = BlobStore(
                endpoint="localhost:9000",
                access_key="access",
                secret_key="secret",
                bucket_name="test-bucket"
            )
    return store, mock_minio

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_oss_uses_ecs_role_and_never_creates_bucket():
    mock_minio = MagicMock()
    mock_minio.bucket_exists.return_value = True
    with patch('trustgraph.librarian.blob_store.Minio', return_value=mock_minio) as minio:
        with patch('trustgraph.librarian.blob_store.EcsRamRoleProvider') as role:
            BlobStore(
                endpoint='oss-cn-shenzhen-internal.aliyuncs.com',
                access_key='ignored', secret_key='ignored',
                bucket_name='trustgraph-library',
                use_ssl=True, region='cn-shenzhen',
                provider='oss', role_name='TrustGraphOssRole',
            )

    role.assert_called_once_with('TrustGraphOssRole')
    assert minio.call_args.kwargs['credentials'] is role.return_value
    assert minio.call_args.kwargs['secure'] is True
    assert 'access_key' not in minio.call_args.kwargs
    mock_minio.bucket_exists.assert_called_once_with(
        bucket_name='trustgraph-library',
    )
    mock_minio.make_bucket.assert_not_called()


@pytest.mark.parametrize('role,region,tls', [
    (None, 'cn-shenzhen', True),
    ('TrustGraphOssRole', None, True),
    ('TrustGraphOssRole', 'cn-shenzhen', False),
])
def test_oss_rejects_incomplete_secure_config(role, region, tls):
    with pytest.raises(ValueError, match='OSS requires'):
        BlobStore(
            endpoint='oss-cn-shenzhen-internal.aliyuncs.com',
            access_key=None, secret_key=None,
            bucket_name='trustgraph-library',
            use_ssl=tls, region=region,
            provider='oss', role_name=role,
        )


def test_oss_missing_bucket_fails_without_creating_it():
    mock_minio = MagicMock()
    mock_minio.bucket_exists.return_value = False
    with patch('trustgraph.librarian.blob_store.Minio', return_value=mock_minio):
        with patch('trustgraph.librarian.blob_store.EcsRamRoleProvider'):
            with pytest.raises(RuntimeError, match='OSS bucket does not exist'):
                BlobStore(
                    endpoint='oss-cn-shenzhen-internal.aliyuncs.com',
                    access_key=None, secret_key=None,
                    bucket_name='trustgraph-library',
                    use_ssl=True, region='cn-shenzhen',
                    provider='oss', role_name='TrustGraphOssRole',
                )
    mock_minio.make_bucket.assert_not_called()


def test_ecs_role_provider_returns_one_credential_snapshot():
    with patch('alibabacloud_credentials.client.Client') as client:
        credential = client.return_value.get_credential.return_value
        credential.get_access_key_id.return_value = 'temporary-id'
        credential.get_access_key_secret.return_value = 'temporary-secret'
        credential.get_security_token.return_value = 'temporary-token'
        provider = EcsRamRoleProvider('TrustGraphOssRole')
        result = provider.retrieve()

    assert result.access_key == 'temporary-id'
    assert result.secret_key == 'temporary-secret'
    assert result.session_token == 'temporary-token'
    client.return_value.get_credential.assert_called_once_with()


def test_librarian_forwards_oss_configuration_to_blob_store():
    with patch('trustgraph.librarian.librarian.BlobStore') as blob_store:
        with patch('trustgraph.librarian.librarian.LibraryTableStore'):
            Librarian(
                cassandra_host='cassandra',
                cassandra_username=None,
                cassandra_password=None,
                object_store_endpoint='oss-cn-shenzhen-internal.aliyuncs.com',
                object_store_access_key=None,
                object_store_secret_key=None,
                bucket_name='trustgraph-library',
                keyspace='librarian',
                load_document=None,
                object_store_use_ssl=True,
                object_store_region='cn-shenzhen',
                object_store_provider='oss',
                object_store_role_name='TrustGraphOssRole',
            )

    assert blob_store.call_args.kwargs == {
        'use_ssl': True,
        'region': 'cn-shenzhen',
        'provider': 'oss',
        'role_name': 'TrustGraphOssRole',
    }
    assert blob_store.call_args.args[3] == 'trustgraph-library'

@pytest.mark.asyncio
async def test_add_success_no_retry():
    store, mock_minio = _make_blob_store()
    object_id = uuid4()
    
    await store.add(object_id, b"data", "text/plain")

    mock_minio.put_object.assert_called_once()

@pytest.mark.asyncio
async def test_retry_recovery_on_transient_failure():
    store, mock_minio = _make_blob_store()
    store.base_delay = 0  # Disable delay for fast tests
    
    # Fail twice, succeed third time
    mock_minio.put_object.side_effect = [
        Exception("Error 1"),
        Exception("Error 2"),
        MagicMock()
    ]

    await store.add(uuid4(), b"data", "text/plain")
    
    assert mock_minio.put_object.call_count == 3

@pytest.mark.asyncio
async def test_retry_exhaustion_after_8_attempts():
    store, mock_minio = _make_blob_store()
    store.base_delay = 0
    
    # Permanent failure
    mock_minio.put_object.side_effect = Exception("Permanent failure")

    with pytest.raises(Exception, match="Permanent failure"):
        await store.add(uuid4(), b"data", "text/plain")
    
    # Author requirement: exactly 8 attempts
    assert mock_minio.put_object.call_count == 8

@pytest.mark.asyncio
async def test_s3_error_triggers_retry():
    store, mock_minio = _make_blob_store()
    store.base_delay = 0
    
    # Mock S3Error
    s3_err = S3Error("code", "msg", "res", "req", "host", None)
    mock_minio.get_object.side_effect = [s3_err, MagicMock()]

    await store.get(uuid4())
    
    assert mock_minio.get_object.call_count == 2

@pytest.mark.asyncio
async def test_exponential_backoff_delays():
    store, mock_minio = _make_blob_store()
    # Use real base_delay to check math
    store.base_delay = 0.25
    
    # Correct method name is stat_object, not get_size
    mock_minio.stat_object = MagicMock(side_effect=Exception("Wait"))

    with patch('asyncio.sleep', new_callable=AsyncMock) as mock_sleep:
        with pytest.raises(Exception):
            await store.get_size(uuid4())
        
        # Should have 7 sleep calls for 8 attempts
        assert mock_sleep.call_count == 7
        
        # Check actual sleep durations: 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0
        sleep_args = [call[0][0] for call in mock_sleep.call_args_list]
        assert sleep_args == [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]

@pytest.mark.asyncio
async def test_runs_in_executor():
    """Verify that synchronous Minio calls are offloaded to an executor."""
    store, mock_minio = _make_blob_store()
    
    # Mock response object with .read() method
    mock_response = MagicMock()
    mock_response.read.return_value = b"result"

    with patch('asyncio.get_event_loop') as mock_loop:
        mock_loop_instance = MagicMock()
        mock_loop.return_value = mock_loop_instance
        mock_loop_instance.run_in_executor = AsyncMock(return_value=mock_response)

        await store.get(uuid4())
        
        mock_loop_instance.run_in_executor.assert_called_once()
