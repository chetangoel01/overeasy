class AcquisitionError(Exception):
    pass


class PrivateOrDeleted(AcquisitionError):
    pass


class TranscriptUnavailable(AcquisitionError):
    pass


class ProviderUnavailable(AcquisitionError):
    pass


class ProviderTransientError(ProviderUnavailable):
    pass


class ProviderAuthenticationError(ProviderUnavailable):
    pass


class ProviderQuotaError(ProviderUnavailable):
    pass


class MalformedProviderResponse(ProviderUnavailable):
    pass


class EmptyProviderResponse(ProviderUnavailable):
    pass
