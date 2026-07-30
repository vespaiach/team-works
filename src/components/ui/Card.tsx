interface CardProps extends React.HTMLAttributes<HTMLDivElement> {}

export function Card({ className = "", children, ...props }: CardProps) {
  return (
    <div className={`rounded-lg border bg-white p-6 shadow-sm ${className}`} {...props}>
      {children}
    </div>
  );
}
