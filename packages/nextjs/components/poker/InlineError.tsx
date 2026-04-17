export const InlineError = ({ message }: { message?: string | null }) => {
  if (!message) return null;
  return (
    <div className="alert alert-error py-2 text-sm mt-2">
      <span>{message}</span>
    </div>
  );
};
