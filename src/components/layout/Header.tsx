import Link from "next/link";

export function Header() {
  return (
    <header className="border-b">
      <nav className="mx-auto flex max-w-7xl items-center justify-between p-4">
        <Link href="/" className="text-xl font-bold">
          team-works
        </Link>
        <div className="flex gap-4">
          <Link href="/about" className="hover:text-blue-600">
            About
          </Link>
        </div>
      </nav>
    </header>
  );
}
