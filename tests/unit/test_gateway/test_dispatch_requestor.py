"""
Tests for Gateway Service Requestor
"""

import pytest
from unittest.mock import MagicMock, AsyncMock, patch

from trustgraph.gateway.dispatch.requestor import ServiceRequestor


class TestServiceRequestor:
    """Test cases for ServiceRequestor class"""

    def test_service_requestor_initialization(self):
        """Test ServiceRequestor initialization"""
        mock_backend = MagicMock()
        mock_request_schema = MagicMock()
        mock_response_schema = MagicMock()

        requestor = ServiceRequestor(
            backend=mock_backend,
            request_queue="test-request-queue",
            request_schema=mock_request_schema,
            response_queue="test-response-queue",
            response_schema=mock_response_schema,
            subscription="test-subscription",
            consumer_name="test-consumer",
            timeout=300
        )

        assert requestor.backend is mock_backend
        assert requestor.request_queue == "test-request-queue"
        assert requestor.request_schema is mock_request_schema
        assert requestor.response_queue == "test-response-queue"
        assert requestor.response_schema is mock_response_schema
        assert requestor.timeout == 300
        assert requestor.running is True
        assert requestor.client is None

    def test_service_requestor_with_defaults(self):
        """Test ServiceRequestor initialization with default parameters"""
        mock_backend = MagicMock()
        mock_request_schema = MagicMock()
        mock_response_schema = MagicMock()

        requestor = ServiceRequestor(
            backend=mock_backend,
            request_queue="test-queue",
            request_schema=mock_request_schema,
            response_queue="response-queue",
            response_schema=mock_response_schema
        )

        # Verify default values
        assert requestor.timeout == 600  # Default timeout
        assert requestor.running is True
        assert requestor.client is None

    @patch('trustgraph.gateway.dispatch.requestor.RequestResponseClient')
    @pytest.mark.asyncio
    async def test_service_requestor_start(self, mock_rrc_class):
        """Test ServiceRequestor start method"""
        mock_backend = MagicMock()
        mock_request_schema = MagicMock()
        mock_response_schema = MagicMock()
        mock_client_instance = AsyncMock()
        mock_rrc_class.create = AsyncMock(return_value=mock_client_instance)

        requestor = ServiceRequestor(
            backend=mock_backend,
            request_queue="test-queue",
            request_schema=mock_request_schema,
            response_queue="response-queue",
            response_schema=mock_response_schema
        )

        # Call start
        await requestor.start()

        # Verify RequestResponseClient.create was called correctly
        mock_rrc_class.create.assert_called_once_with(
            backend=mock_backend,
            request_topic="test-queue",
            response_topic="response-queue",
            request_schema=mock_request_schema,
            response_schema=mock_response_schema,
            processor_id="api-gateway",
            target_service=None,
        )
        assert requestor.client is mock_client_instance
        assert requestor.running is True

    @patch('trustgraph.gateway.dispatch.requestor.RequestResponseClient')
    @pytest.mark.asyncio
    async def test_service_requestor_stop(self, mock_rrc_class):
        """Test ServiceRequestor stop method"""
        mock_client_instance = AsyncMock()
        mock_rrc_class.create = AsyncMock(return_value=mock_client_instance)

        requestor = ServiceRequestor(
            backend=MagicMock(),
            request_queue="test-queue",
            request_schema=MagicMock(),
            response_queue="response-queue",
            response_schema=MagicMock()
        )

        await requestor.start()
        await requestor.stop()

        assert requestor.running is False
        mock_client_instance.close.assert_called_once()
        assert requestor.client is None

    def test_service_requestor_attributes(self):
        """Test ServiceRequestor has correct attributes"""
        mock_backend = MagicMock()

        requestor = ServiceRequestor(
            backend=mock_backend,
            request_queue="test-queue",
            request_schema=MagicMock(),
            response_queue="response-queue",
            response_schema=MagicMock()
        )

        # Verify attributes are set correctly
        assert requestor.client is None
        assert requestor.running is True


class _EmptyTranslatorRequestor(ServiceRequestor):
    """Mimics a translator (e.g. flow, iam) that never encodes resp.error."""

    def to_request(self, request):
        return request

    def from_response(self, response):
        return {}, True


def _error_resp():
    resp = MagicMock()
    resp.error.type = "flow-error"
    resp.error.message = "Flow ID invalid"
    return resp


def _requestor_with_client(client):
    requestor = _EmptyTranslatorRequestor(
        backend=MagicMock(),
        request_queue="q", request_schema=MagicMock(),
        response_queue="r", response_schema=MagicMock(),
    )
    requestor.client = client
    return requestor


class TestServiceRequestorErrors:
    """Errors must reach the client even when the translator drops them."""

    @pytest.mark.asyncio
    async def test_request_error_is_reported(self):
        client = MagicMock()
        client.request = AsyncMock(return_value=_error_resp())
        requestor = _requestor_with_client(client)

        with patch('trustgraph.gateway.dispatch.requestor._init_gateway_metrics'):
            ServiceRequestor.gateway_request_metric = MagicMock()
            ServiceRequestor.gateway_request_duration_metric = MagicMock()
            result = await requestor.process({})

        assert result == {"error": {
            "type": "flow-error", "message": "Flow ID invalid",
        }}

    @pytest.mark.asyncio
    async def test_stream_error_is_reported_as_final(self):
        async def stream(*args, **kwargs):
            yield _error_resp()

        client = MagicMock()
        client.request_stream = stream
        requestor = _requestor_with_client(client)
        responder = AsyncMock()

        ServiceRequestor.gateway_request_metric = MagicMock()
        ServiceRequestor.gateway_request_duration_metric = MagicMock()
        result = await requestor.process({}, responder)

        expected = {"error": {
            "type": "flow-error", "message": "Flow ID invalid",
        }}
        responder.assert_awaited_once_with(expected, True)
        assert result == expected

    @pytest.mark.asyncio
    async def test_success_still_uses_translator(self):
        resp = MagicMock()
        resp.error = None
        client = MagicMock()
        client.request = AsyncMock(return_value=resp)
        requestor = _requestor_with_client(client)

        ServiceRequestor.gateway_request_metric = MagicMock()
        ServiceRequestor.gateway_request_duration_metric = MagicMock()
        assert await requestor.process({}) == {}
