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


class VisualAnalysisUnavailable(ProviderUnavailable):
    """Nothing could be seen: no media, no frames, or nothing worth reporting.

    A ProviderUnavailable so the chain treats a video we could not watch the
    same way it treats a provider that would not answer — it keeps going.
    """
