namespace PickyVPN.App
{
    // A Credential screen is an edit session: navigation away abandons this object,
    // while Save is the only point that can persist or remove a credential source.
    internal sealed class CredentialDraft
    {
        internal CredentialDraft(string persistedValue)
        {
            Value = persistedValue ?? string.Empty;
        }

        internal string Value { get; private set; }
        internal bool ShouldDelete { get { return deleteRequested && string.IsNullOrWhiteSpace(Value); } }

        private bool deleteRequested;

        internal void Edit(string value)
        {
            Value = value ?? string.Empty;
            deleteRequested = false;
        }

        internal void Clear()
        {
            Value = string.Empty;
            deleteRequested = true;
        }
    }
}
